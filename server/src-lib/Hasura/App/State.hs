{-# LANGUAGE Arrows #-}

module Hasura.App.State
  ( RebuildableAppContext (..),
    AppEnv (..),
    AppContext (..),
    Loggers (..),
    buildRebuildableAppContext,
    initSQLGenCtx,
  )
where

import Control.Arrow.Extended
import Control.Concurrent.STM qualified as STM
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Environment qualified as E
import Data.HashSet qualified as Set
import Database.PG.Query qualified as PG
import Hasura.Base.Error
import Hasura.Eventing.Common (LockedEventsCtx)
import Hasura.Eventing.EventTrigger
import Hasura.GraphQL.Execute.Subscription.Options
import Hasura.GraphQL.Execute.Subscription.State qualified as ES
import Hasura.GraphQL.Schema.NamingCase
import Hasura.GraphQL.Schema.Options qualified as Options
import Hasura.Incremental qualified as Inc
import Hasura.Logging qualified as L
import Hasura.Prelude
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.Metadata
import Hasura.RQL.Types.SchemaCache (MetadataResourceVersion)
import Hasura.Server.Auth
import Hasura.Server.Cors qualified as Cors
import Hasura.Server.Init
import Hasura.Server.Logging
import Hasura.Server.Metrics
import Hasura.Server.Prometheus
import Hasura.Server.Types
import Hasura.Session
import Hasura.ShutdownLatch
import Hasura.Tracing qualified as Tracing
import Network.HTTP.Client qualified as HTTP
import Network.Wai.Handler.Warp (HostPreference)
import Network.WebSockets.Connection qualified as WebSockets
import Refined (NonNegative, Refined)

{- Note [Hasura Application State]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Hasura Application state represents the entire state of hasura.

Hasura Application State = AppEnv (static) + AppContext (dynamic)

Hasura Application State can be divided into two parts:

  1. Read-Only State (Static State):
  =================================
  The information required to build this state is provided only during the
  initialization of hasura. This information is immutable. If you want update any
  field in this state, you would need to shutdown the current instance and
  re-launch hausura with new information.

  Eg: If you want to run hasura in read-only mode, you would have to mention
      this information when hasura starts up. There is no way to make hasura
      run in read-only mode once it has booted up.

  2. Runtime Configurable State (Dynamic State):
  ==============================================
  The information present in this state can be updated during the runtime. This state
  is mutable and does not require a restart of hasura instance to take effect.

  The fields in the state are usually updated via Metadata API's or Hasura Console.

  Eg: You can change the entries in Allowlist via console and hasura need not restart
      for the changes to take effect.

-}

data RebuildableAppContext impl = RebuildableAppContext
  { lastBuiltAppContext :: AppContext,
    _racInvalidationMap :: InvalidationKeys,
    _racRebuild :: Inc.Rule (ReaderT (L.Logger L.Hasura, HTTP.Manager) (ExceptT QErr IO)) (ServeOptions impl, E.Environment, InvalidationKeys) AppContext
  }

-- | Represents the Read-Only Hasura State, these fields are immutable and the state
-- cannot be changed during runtime.
data AppEnv = AppEnv
  { appEnvPort :: Port,
    appEnvHost :: HostPreference,
    appEnvMetadataDbPool :: PG.PGPool,
    appEnvManager :: HTTP.Manager,
    appEnvLoggers :: Loggers,
    appEnvMetadataVersionRef :: STM.TMVar MetadataResourceVersion,
    appEnvInstanceId :: InstanceId,
    appEnvEnableMaintenanceMode :: MaintenanceMode (),
    appEnvLoggingSettings :: LoggingSettings,
    appEnvEventingMode :: EventingMode,
    appEnvEnableReadOnlyMode :: ReadOnlyMode,
    appEnvServerMetrics :: ServerMetrics,
    appEnvShutdownLatch :: ShutdownLatch,
    appEnvMetaVersionRef :: STM.TMVar MetadataResourceVersion,
    appEnvPrometheusMetrics :: PrometheusMetrics,
    appEnvTraceSamplingPolicy :: Tracing.SamplingPolicy,
    appEnvSubscriptionState :: ES.SubscriptionsState,
    appEnvLockedEventsCtx :: LockedEventsCtx,
    appEnvConnParams :: PG.ConnParams,
    appEnvTxIso :: PG.TxIsolation,
    appEnvConsoleAssetsDir :: Maybe Text,
    appEnvConsoleSentryDsn :: Maybe Text,
    appEnvConnectionOptions :: WebSockets.ConnectionOptions,
    appEnvWebSocketKeepAlive :: KeepAliveDelay,
    appEnvWebSocketConnectionInitTimeout :: WSConnectionInitTimeout,
    appEnvGracefulShutdownTimeout :: Refined NonNegative Seconds,
    -- TODO: Move this to `ServerContext`. We are leaving this for now as this cannot be changed directly
    -- by the user on the cloud dashboard and will also require a refactor in HasuraPro/App.hs
    -- as this thread is initialised there before creating the `AppStateRef`. But eventually we need
    -- to do it for the Enterprise version.
    appEnvSchemaPollInterval :: OptionalInterval,
    appEnvCheckFeatureFlag :: (FeatureFlag -> IO Bool)
  }

-- | Represents the Dynamic Hasura State, these field are mutable and can be changed
-- during runtime.
data AppContext = AppContext
  { acAuthMode :: AuthMode,
    acSQLGenCtx :: SQLGenCtx,
    acEnabledAPIs :: Set.HashSet API,
    acEnableAllowlist :: AllowListStatus,
    acResponseInternalErrorsConfig :: ResponseInternalErrorsConfig,
    acEnvironment :: E.Environment,
    acRemoteSchemaPermsCtx :: Options.RemoteSchemaPermissions,
    acFunctionPermsCtx :: Options.InferFunctionPermissions,
    acExperimentalFeatures :: Set.HashSet ExperimentalFeature,
    acDefaultNamingConvention :: NamingCase,
    acMetadataDefaults :: MetadataDefaults,
    acLiveQueryOptions :: LiveQueriesOptions,
    acStreamQueryOptions :: StreamQueriesOptions,
    acCorsPolicy :: Cors.CorsPolicy,
    acConsoleStatus :: ConsoleStatus,
    acEnableTelemetry :: TelemetryStatus,
    acEventEngineCtx :: EventEngineCtx,
    acAsyncActionsFetchInterval :: OptionalInterval,
    acApolloFederationStatus :: ApolloFederationStatus
  }

-- | Collection of the LoggerCtx, the regular Logger and the PGLogger
data Loggers = Loggers
  { _lsLoggerCtx :: L.LoggerCtx L.Hasura,
    _lsLogger :: L.Logger L.Hasura,
    _lsPgLogger :: PG.PGLogger
  }

data InvalidationKeys = InvalidationKeys

initInvalidationKeys :: InvalidationKeys
initInvalidationKeys = InvalidationKeys

-- | Function to build the 'AppContext' (given the 'ServeOptions') for the first
-- time
buildRebuildableAppContext :: (L.Logger L.Hasura, HTTP.Manager) -> ServeOptions impl -> E.Environment -> ExceptT QErr IO (RebuildableAppContext impl)
buildRebuildableAppContext readerContext serveOptions env = do
  result <- flip runReaderT readerContext $ Inc.build (buildAppContextRule) (serveOptions, env, initInvalidationKeys)
  let !appContext = Inc.result result
  let !rebuildableAppContext = RebuildableAppContext appContext initInvalidationKeys (Inc.rebuildRule result)
  pure rebuildableAppContext

buildAppContextRule ::
  forall arr m impl.
  ( ArrowChoice arr,
    Inc.ArrowCache m arr,
    MonadBaseControl IO m,
    MonadIO m,
    MonadError QErr m,
    MonadReader (L.Logger L.Hasura, HTTP.Manager) m
  ) =>
  (ServeOptions impl, E.Environment, InvalidationKeys) `arr` AppContext
buildAppContextRule = proc (ServeOptions {..}, env, _keys) -> do
  authMode <- buildAuthMode -< (soAdminSecret, soAuthHook, soJwtSecret, soUnAuthRole)
  sqlGenCtx <- buildSqlGenCtx -< (soExperimentalFeatures, soStringifyNum, soDangerousBooleanCollapse)
  responseInternalErrorsConfig <- buildResponseInternalErrorsConfig -< (soAdminInternalErrors, soDevMode)
  eventEngineCtx <- buildEventEngineCtx -< (soEventsHttpPoolSize, soEventsFetchInterval, soEventsFetchBatchSize)
  returnA
    -<
      AppContext
        { acAuthMode = authMode,
          acSQLGenCtx = sqlGenCtx,
          acEnabledAPIs = soEnabledAPIs,
          acEnableAllowlist = soEnableAllowList,
          acResponseInternalErrorsConfig = responseInternalErrorsConfig,
          acEnvironment = env,
          acRemoteSchemaPermsCtx = soEnableRemoteSchemaPermissions,
          acFunctionPermsCtx = soInferFunctionPermissions,
          acExperimentalFeatures = soExperimentalFeatures,
          acDefaultNamingConvention = soDefaultNamingConvention,
          acMetadataDefaults = soMetadataDefaults,
          acLiveQueryOptions = soLiveQueryOpts,
          acStreamQueryOptions = soStreamingQueryOpts,
          acCorsPolicy = Cors.mkDefaultCorsPolicy soCorsConfig,
          acConsoleStatus = soConsoleStatus,
          acEnableTelemetry = soEnableTelemetry,
          acEventEngineCtx = eventEngineCtx,
          acAsyncActionsFetchInterval = soAsyncActionsFetchInterval,
          acApolloFederationStatus = soApolloFederationStatus
        }
  where
    buildSqlGenCtx = Inc.cache proc (experimentalFeatures, stringifyNum, dangerousBooleanCollapse) -> do
      let sqlGenCtx = initSQLGenCtx experimentalFeatures stringifyNum dangerousBooleanCollapse
      returnA -< sqlGenCtx

    buildEventEngineCtx = Inc.cache proc (httpPoolSize, fetchInterval, fetchBatchSize) -> do
      eventEngineCtx <- bindA -< initEventEngineCtx httpPoolSize fetchInterval fetchBatchSize
      returnA -< eventEngineCtx

    buildAuthMode :: (Set.HashSet AdminSecretHash, Maybe AuthHook, [JWTConfig], Maybe RoleName) `arr` AuthMode
    buildAuthMode = Inc.cache proc (adminSecretHashSet, webHook, jwtSecrets, unAuthRole) -> do
      authMode <-
        bindA
          -< do
            (logger, httpManager) <- ask
            authModeRes <-
              runExceptT $
                setupAuthMode
                  adminSecretHashSet
                  webHook
                  jwtSecrets
                  unAuthRole
                  logger
                  httpManager
            onLeft authModeRes throw500
      returnA -< authMode

    buildResponseInternalErrorsConfig :: (AdminInternalErrorsStatus, DevModeStatus) `arr` ResponseInternalErrorsConfig
    buildResponseInternalErrorsConfig = Inc.cache proc (adminInternalErrors, devMode) -> do
      let responseInternalErrorsConfig =
            if
                | isDevModeEnabled devMode -> InternalErrorsAllRequests
                | isAdminInternalErrorsEnabled adminInternalErrors -> InternalErrorsAdminOnly
                | otherwise -> InternalErrorsDisabled
      returnA -< responseInternalErrorsConfig

initSQLGenCtx :: HashSet ExperimentalFeature -> Options.StringifyNumbers -> Options.DangerouslyCollapseBooleans -> SQLGenCtx
initSQLGenCtx experimentalFeatures stringifyNum dangerousBooleanCollapse =
  let optimizePermissionFilters
        | EFOptimizePermissionFilters `elem` experimentalFeatures = Options.OptimizePermissionFilters
        | otherwise = Options.Don'tOptimizePermissionFilters

      bigqueryStringNumericInput
        | EFBigQueryStringNumericInput `elem` experimentalFeatures = Options.EnableBigQueryStringNumericInput
        | otherwise = Options.DisableBigQueryStringNumericInput
   in SQLGenCtx stringifyNum dangerousBooleanCollapse optimizePermissionFilters bigqueryStringNumericInput