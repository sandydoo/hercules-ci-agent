module Hercules.Agent.Effect where

import qualified Data.Aeson as A
import Data.IORef
import qualified Data.Map as M
import qualified Hercules.API.Agent.Effect.EffectTask as EffectTask
import Hercules.API.TaskStatus (TaskStatus)
import qualified Hercules.API.TaskStatus as TaskStatus
import qualified Hercules.Agent.Config as Config
import Hercules.Agent.Env hiding (config)
import qualified Hercules.Agent.Env as Env
import Hercules.Agent.Files
import Hercules.Agent.Log
import qualified Hercules.Agent.Nix as Nix
import Hercules.Agent.Sensitive (Sensitive (Sensitive))
import qualified Hercules.Agent.ServiceInfo as ServiceInfo
import Hercules.Agent.WorkerProcess
import qualified Hercules.Agent.WorkerProcess as WorkerProcess
import qualified Hercules.Agent.WorkerProtocol.Command as Command
import qualified Hercules.Agent.WorkerProtocol.Command.Effect as Command.Effect
import qualified Hercules.Agent.WorkerProtocol.Event as Event
import qualified Hercules.Agent.WorkerProtocol.LogSettings as LogSettings
import Hercules.Agent.WorkerProtocol.ViaJSON (ViaJSON (ViaJSON))
import qualified Hercules.Secrets as Secrets
import qualified Network.URI
import Protolude
import qualified System.Posix.Signals as PS
import System.Process

performEffect :: EffectTask.EffectTask -> App TaskStatus
performEffect effectTask = withWorkDir "effect" $ \workDir -> do
  workerExe <- getWorkerExe
  commandChan <- liftIO newChan
  extraNixOptions <- Nix.askExtraOptions
  workerEnv <-
    liftIO $
      WorkerProcess.prepareEnv
        ( WorkerProcess.WorkerEnvSettings
            { nixPath = mempty,
              extraEnv = mempty
            }
        )
  effectResult <- liftIO $ newIORef Nothing
  let opts = [show extraNixOptions]
      procSpec =
        (System.Process.proc workerExe opts)
          { env = Just workerEnv,
            close_fds = True,
            cwd = Just workDir
          }
      writeEvent :: Event.Event -> App ()
      writeEvent event = case event of
        Event.EffectResult e -> do
          liftIO $ writeIORef effectResult (Just e)
        Event.Exception e -> do
          panic e
        _ -> pass
  config <- asks Env.config
  let materialize = not (Config.nixUserIsTrusted config)
  baseURL <- asks (ServiceInfo.bulkSocketBaseURL . Env.serviceInfo)
  liftIO $
    writeChan commandChan $
      Just $
        Command.Effect $
          Command.Effect.Effect
            { drvPath = EffectTask.derivationPath effectTask,
              inputDerivationOutputPaths = encodeUtf8 <$> EffectTask.inputDerivationOutputPaths effectTask,
              logSettings =
                LogSettings.LogSettings
                  { token = Sensitive $ EffectTask.logToken effectTask,
                    path = "/api/v1/logs/build/socket",
                    baseURL = toS $ Network.URI.uriToString identity baseURL ""
                  },
              materializeDerivation = materialize,
              secretsPath = toS $ Config.secretsJsonPath config,
              serverSecrets = Sensitive $ ViaJSON (EffectTask.serverSecrets effectTask),
              token = Sensitive (EffectTask.token effectTask),
              apiBaseURL = Config.herculesApiBaseURL config,
              projectId = EffectTask.projectId effectTask,
              projectPath = EffectTask.projectPath effectTask,
              secretContext =
                Secrets.SecretContext
                  { ownerName = EffectTask.ownerName effectTask,
                    repoName = EffectTask.repoName effectTask,
                    ref = EffectTask.ref effectTask,
                    isDefaultBranch = EffectTask.isDefaultBranch effectTask
                  }
            }
  let stderrHandler =
        stderrLineHandler
          ( M.fromList
              [ ("taskId", A.toJSON (EffectTask.id effectTask)),
                ("derivationPath", A.toJSON (EffectTask.derivationPath effectTask))
              ]
          )
          "Effect worker"
  exitCode <- runWorker procSpec stderrHandler commandChan writeEvent
  logLocM DebugS $ "Worker exit: " <> logStr (show exitCode :: Text)
  let showSig n | n == PS.sigABRT = " (Aborted)"
      showSig n | n == PS.sigBUS = " (Bus)"
      showSig n | n == PS.sigCHLD = " (Child)"
      showSig n | n == PS.sigFPE = " (Floating point exception)"
      showSig n | n == PS.sigHUP = " (Hangup)"
      showSig n | n == PS.sigILL = " (Illegal instruction)"
      showSig n | n == PS.sigINT = " (Interrupted)"
      showSig n | n == PS.sigKILL = " (Killed)"
      showSig n | n == PS.sigPIPE = " (Broken pipe)"
      showSig n | n == PS.sigQUIT = " (Quit)"
      showSig n | n == PS.sigSEGV = " (Segmentation fault)"
      showSig n | n == PS.sigTERM = " (Terminated)"
      showSig _ = ""
  case exitCode of
    ExitSuccess -> pass
    ExitFailure n -> panic $ "Effect worker failed with exit code " <> show n <> showSig (negate $ fromIntegral n)
  liftIO (readIORef effectResult) >>= \case
    Nothing -> pure $ TaskStatus.Exceptional "Effect worker terminated without reporting status"
    Just 0 -> pure $ TaskStatus.Successful ()
    Just n | n > 0 -> pure $ TaskStatus.Terminated ()
    Just n -> pure $ TaskStatus.Exceptional $ "Effect process exited with status code " <> show n <> showSig (negate $ fromIntegral n)
