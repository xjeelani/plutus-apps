{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

{-

A live, multi-threaded PAB simulator with agent-specific states and actions
on them. Agents are represented by the 'Wallet' type. Each agent corresponds
to one PAB, with its own view of the world, all acting on the same blockchain.

-}
module Plutus.PAB.Simulator(
    Simulation
    , SimulatorState
    -- * Run with user-defined contracts
    , SimulatorContractHandler
    , runSimulationWith
    , SimulatorEffectHandlers
    , mkSimulatorHandlers
    , addWallet
    -- * Logging
    , logString
    -- ** Agent actions
    , payToWallet
    , payToPublicKeyHash
    , activateContract
    , callEndpointOnInstance
    , handleAgentThread
    , Activity(..)
    , stopInstance
    , instanceActivity
    -- ** Control actions
    , makeBlock
    -- * Querying the state
    , instanceState
    , observableState
    , waitForState
    , activeEndpoints
    , waitForEndpoint
    , waitForTxStatusChange
    , waitForTxOutStatusChange
    , currentSlot
    , waitUntilSlot
    , waitNSlots
    , activeContracts
    , finalResult
    , waitUntilFinished
    , valueAt
    , valueAtSTM
    , walletFees
    , blockchain
    , currentBalances
    , logBalances
    -- ** Transaction counts
    , TxCounts(..)
    , txCounts
    , txCountsSTM
    , txValidated
    , txMemPool
    , waitForValidatedTxCount
    ) where

import Cardano.Wallet.Mock.Handlers qualified as MockWallet
import Control.Concurrent (forkIO)
import Control.Concurrent.STM (STM, TQueue, TVar)
import Control.Concurrent.STM qualified as STM
import Control.Lens (_Just, at, makeLenses, makeLensesFor, preview, set, view, (&), (.~), (?~), (^.))
import Control.Monad (forM_, forever, guard, void, when)
import Control.Monad.Freer (Eff, LastMember, Member, interpret, reinterpret, reinterpret2, reinterpretN, run, send,
                            type (~>))
import Control.Monad.Freer.Delay (DelayEffect, delayThread, handleDelayEffect)
import Control.Monad.Freer.Error (Error, handleError, runError, throwError)
import Control.Monad.Freer.Extras qualified as Modify
import Control.Monad.Freer.Extras.Log (LogLevel (Info), LogMessage, LogMsg (..), handleLogWriter, logInfo, logLevel,
                                       mapLog)
import Control.Monad.Freer.Reader (Reader, ask, asks)
import Control.Monad.Freer.State (State (..), runState)
import Control.Monad.Freer.Writer (Writer (..), runWriter)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson qualified as JSON
import Data.Default (Default (..))
import Data.Foldable (fold, traverse_)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time.Units (Millisecond)
import Ledger (Address (..), Blockchain, CardanoTx, PubKeyHash, TxId, TxOut (..), eitherTx, txFee, txId)
import Ledger.Ada qualified as Ada
import Ledger.CardanoWallet (MockWallet)
import Ledger.CardanoWallet qualified as CW
import Ledger.Fee (FeeConfig)
import Ledger.Index qualified as UtxoIndex
import Ledger.TimeSlot (SlotConfig (..))
import Ledger.Value (Value, flattenValue)
import Plutus.ChainIndex.Emulator (ChainIndexControlEffect, ChainIndexEmulatorState, ChainIndexError, ChainIndexLog,
                                   ChainIndexQueryEffect (DatumFromHash, GetTip, MintingPolicyFromHash, RedeemerFromHash, StakeValidatorFromHash, TxFromTxId, TxOutFromRef, UtxoSetAtAddress, UtxoSetMembership, UtxoSetWithCurrency, ValidatorFromHash),
                                   TxOutStatus, TxStatus, getTip)
import Plutus.ChainIndex.Emulator qualified as ChainIndex
import Plutus.PAB.Core (EffectHandlers (..))
import Plutus.PAB.Core qualified as Core
import Plutus.PAB.Core.ContractInstance.BlockchainEnv qualified as BlockchainEnv
import Plutus.PAB.Core.ContractInstance.STM (Activity (..), BlockchainEnv (..), OpenEndpoint)
import Plutus.PAB.Core.ContractInstance.STM qualified as Instances
import Plutus.PAB.Effects.Contract (ContractStore)
import Plutus.PAB.Effects.Contract qualified as Contract
import Plutus.PAB.Effects.Contract.Builtin (HasDefinitions (..))
import Plutus.PAB.Effects.TimeEffect (TimeEffect)
import Plutus.PAB.Monitoring.PABLogMsg (PABMultiAgentMsg (..))
import Plutus.PAB.Types (PABError (ContractInstanceNotFound, WalletError, WalletNotFound))
import Plutus.PAB.Webserver.Types (ContractActivationArgs (..))
import Plutus.Trace.Emulator.System (appendNewTipBlock)
import Plutus.V1.Ledger.Slot (Slot)
import Plutus.V1.Ledger.Tx (TxOutRef)
import Prettyprinter (Pretty (pretty), defaultLayoutOptions, layoutPretty)
import Prettyprinter.Render.Text qualified as Render
import Wallet.API qualified as WAPI
import Wallet.Effects (NodeClientEffect (..), WalletEffect)
import Wallet.Emulator qualified as Emulator
import Wallet.Emulator.Chain (ChainControlEffect, ChainState (..))
import Wallet.Emulator.Chain qualified as Chain
import Wallet.Emulator.LogMessages (TxBalanceMsg)
import Wallet.Emulator.MultiAgent (EmulatorEvent' (..), _singleton)
import Wallet.Emulator.Stream qualified as Emulator
import Wallet.Emulator.Wallet (Wallet (..), knownWallet, knownWallets)
import Wallet.Emulator.Wallet qualified as Wallet
import Wallet.Types (ContractInstanceId, NotificationError)

-- | The current state of a contract instance
data SimulatorContractInstanceState t =
    SimulatorContractInstanceState
        { _contractDef   :: ContractActivationArgs (Contract.ContractDef t)
        , _contractState :: Contract.State t
        }

makeLensesFor [("_contractState", "contractState")] ''SimulatorContractInstanceState

data AgentState t =
    AgentState
        { _walletState   :: Wallet.WalletState
        , _submittedFees :: Map TxId Value
        }

makeLenses ''AgentState

initialAgentState :: forall t. MockWallet -> AgentState t
initialAgentState mw=
    AgentState
        { _walletState   = Wallet.fromMockWallet mw
        , _submittedFees = mempty
        }

data SimulatorState t =
    SimulatorState
        { _logMessages :: TQueue (LogMessage (PABMultiAgentMsg t))
        , _chainState  :: TVar ChainState
        , _agentStates :: TVar (Map Wallet (AgentState t))
        , _chainIndex  :: TVar ChainIndexEmulatorState
        , _instances   :: TVar (Map ContractInstanceId (SimulatorContractInstanceState t))
        }

makeLensesFor [("_logMessages", "logMessages"), ("_instances", "instances")] ''SimulatorState

initialState :: forall t. IO (SimulatorState t)
initialState = do
    let initialDistribution = Map.fromList $ fmap (, Ada.adaValueOf 100_000) knownWallets
        Emulator.EmulatorState{Emulator._chainState} = Emulator.initialState (def & Emulator.initialChainState .~ Left initialDistribution)
        initialWallets = Map.fromList $ fmap (\w -> (Wallet.Wallet $ Wallet.WalletId $ CW.mwWalletId w, initialAgentState w)) CW.knownWallets
    STM.atomically $
        SimulatorState
            <$> STM.newTQueue
            <*> STM.newTVar _chainState
            <*> STM.newTVar initialWallets
            <*> STM.newTVar mempty
            <*> STM.newTVar mempty

-- | A handler for the 'ContractEffect' of @t@ that can run contracts in a
--   simulated environment.
type SimulatorContractHandler t =
    forall effs.
        ( Member (Error PABError) effs
        , Member (LogMsg (PABMultiAgentMsg t)) effs
        )
        => Eff (Contract.ContractEffect t ': effs)
        ~> Eff effs

type SimulatorEffectHandlers t = EffectHandlers t (SimulatorState t)

-- | Build 'EffectHandlers' for running a contract in the simulator.
mkSimulatorHandlers ::
    forall t.
    ( Pretty (Contract.ContractDef t)
    , HasDefinitions (Contract.ContractDef t)
    )
    => FeeConfig
    -> SlotConfig
    -> SimulatorContractHandler t -- ^ Making calls to the contract (see 'Plutus.PAB.Effects.Contract.ContractTest.handleContractTest' for an example)
    -> SimulatorEffectHandlers t
mkSimulatorHandlers feeCfg slotCfg handleContractEffect =
    EffectHandlers
        { initialiseEnvironment =
            (,,)
                <$> liftIO (STM.atomically Instances.emptyInstancesState)
                <*> liftIO (STM.atomically Instances.emptyBlockchainEnv)
                <*> liftIO (initialState @t)
        , handleContractStoreEffect =
            interpret handleContractStore
        , handleContractEffect
        , handleLogMessages = handleLogSimulator @t
        , handleServicesEffects = handleServicesSimulator @t feeCfg slotCfg
        , handleContractDefinitionEffect =
            interpret $ \case
                Contract.AddDefinition _ -> pure () -- not supported
                Contract.GetDefinitions  -> pure getDefinitions
        , onStartup = do
            SimulatorState{_logMessages} <- Core.askUserEnv @t @(SimulatorState t)
            void $ liftIO $ forkIO (printLogMessages _logMessages)
            Core.PABRunner{Core.runPABAction} <- Core.pabRunner
            void
                $ liftIO
                $ forkIO
                $ void
                $ runPABAction
                $ handleDelayEffect
                $ interpret (Core.handleUserEnvReader @t @(SimulatorState t))
                $ interpret (Core.handleInstancesStateReader @t @(SimulatorState t))
                $ interpret (Core.handleBlockchainEnvReader @t @(SimulatorState t))
                $ advanceClock @t slotCfg
            Core.waitUntilSlot 1
        , onShutdown = do
            handleDelayEffect $ delayThread (500 :: Millisecond) -- need to wait a little to avoid garbled terminal output in GHCi.
        }

handleLogSimulator ::
    forall t effs.
    ( LastMember IO effs
    , Member (Reader (Core.PABEnvironment t (SimulatorState t))) effs
    )
    => Eff (LogMsg (PABMultiAgentMsg t) ': effs)
    ~> Eff effs
handleLogSimulator =
    interpret (logIntoTQueue @_ @(Core.PABEnvironment t (SimulatorState t)) @effs (view logMessages . Core.appEnv))

handleServicesSimulator ::
    forall t effs.
    ( Member (LogMsg (PABMultiAgentMsg t)) effs
    , Member (Reader (Core.PABEnvironment t (SimulatorState t))) effs
    , Member TimeEffect effs
    , LastMember IO effs
    , Member (Error PABError) effs
    )
    => FeeConfig
    -> SlotConfig
    -> Wallet
    -> Eff (WalletEffect ': ChainIndexQueryEffect ': NodeClientEffect ': effs)
    ~> Eff effs
handleServicesSimulator feeCfg slotCfg wallet =
    let makeTimedChainIndexEvent wllt =
            interpret (mapLog @_ @(PABMultiAgentMsg t) EmulatorMsg)
            . reinterpret (Core.timed @EmulatorEvent')
            . reinterpret (mapLog (ChainIndexEvent wllt))
        makeTimedChainEvent =
            interpret (logIntoTQueue @_ @(Core.PABEnvironment t (SimulatorState t)) @effs (view logMessages . Core.appEnv))
            . reinterpret (mapLog @_ @(PABMultiAgentMsg t) EmulatorMsg)
            . reinterpret (Core.timed @EmulatorEvent' @(LogMsg Emulator.EmulatorEvent ': effs))
            . reinterpret (mapLog ChainEvent)
    in
        -- handle 'NodeClientEffect'
        makeTimedChainEvent
        . interpret (Core.handleBlockchainEnvReader @t @(SimulatorState t))
        . interpret (Core.handleUserEnvReader @t @(SimulatorState t))
        . reinterpretN @'[Reader (SimulatorState t), Reader BlockchainEnv, LogMsg _] (handleChainEffect @t slotCfg)

        . interpret (Core.handleUserEnvReader @t @(SimulatorState t))
        . reinterpret2 (handleNodeClient @t slotCfg wallet)

        -- handle 'ChainIndexQueryEffect'
        . makeTimedChainIndexEvent wallet
        . interpret (Core.handleUserEnvReader @t @(SimulatorState t))
        . reinterpretN @'[Reader (SimulatorState t), LogMsg _] (handleChainIndexEffect @t)

        -- handle 'WalletEffect'
        . interpret (mapLog @_ @(PABMultiAgentMsg t) (WalletBalancingMsg wallet))
        . flip (handleError @WAPI.WalletAPIError) (throwError @PABError . WalletError)
        . interpret (Core.handleUserEnvReader @t @(SimulatorState t))
        . reinterpret (runWalletState @t wallet)
        . reinterpretN @'[State Wallet.WalletState, Error WAPI.WalletAPIError, LogMsg TxBalanceMsg] (Wallet.handleWallet feeCfg)

initialStateFromWallet :: Wallet -> AgentState t
initialStateFromWallet = maybe (error "runWalletState") (initialAgentState . Wallet._mockWallet) . Wallet.emptyWalletState

-- | Handle the 'State WalletState' effect by reading from and writing
--   to a TVar in the 'SimulatorState'
runWalletState ::
    forall t effs.
    ( LastMember IO effs
    , Member (Error PABError) effs
    , Member (Reader (SimulatorState t)) effs
    )
    => Wallet
    -> State Wallet.WalletState
    ~> Eff effs
runWalletState wallet = \case
    Get -> do
        SimulatorState{_agentStates} <- ask @(SimulatorState t)
        result <- liftIO $ STM.atomically $ do
            mp <- STM.readTVar _agentStates
            pure $ Map.lookup wallet mp
        case result of
            Nothing -> throwError $ WalletNotFound wallet
            Just s  -> pure (_walletState s)
    Put s -> do
        SimulatorState{_agentStates} <- ask @(SimulatorState t)
        liftIO $ STM.atomically $ do
            mp <- STM.readTVar _agentStates
            case Map.lookup wallet mp of
                Nothing -> do
                    let ws = maybe (error "runWalletState") (initialAgentState . Wallet._mockWallet) (Wallet.emptyWalletState wallet)
                        newState = ws & walletState .~ s
                    STM.writeTVar _agentStates (Map.insert wallet newState mp)
                Just s' -> do
                    let newState = s' & walletState .~ s
                    STM.writeTVar _agentStates (Map.insert wallet newState mp)

-- | Start a new instance of a contract
activateContract :: forall t. Contract.PABContract t => Wallet -> Contract.ContractDef t -> Simulation t ContractInstanceId
activateContract = Core.activateContract

-- | Call a named endpoint on a contract instance
callEndpointOnInstance :: forall a t. (JSON.ToJSON a) => ContractInstanceId -> String -> a -> Simulation t (Maybe NotificationError)
callEndpointOnInstance = Core.callEndpointOnInstance'

-- | Wait 1 second, then add a new block.
makeBlock ::
    forall t effs.
    ( LastMember IO effs
    , Member (Reader (SimulatorState t)) effs
    , Member (Reader BlockchainEnv) effs
    , Member (Reader Instances.InstancesState) effs
    , Member DelayEffect effs
    , Member TimeEffect effs
    )
    => SlotConfig
    -> Eff effs ()
makeBlock slotCfg@SlotConfig { scSlotLength } = do
    let makeTimedChainEvent =
            interpret (logIntoTQueue @_ @(SimulatorState t) (view logMessages))
            . reinterpret (mapLog @_ @(PABMultiAgentMsg t) EmulatorMsg)
            . reinterpret (Core.timed @EmulatorEvent')
            . reinterpret (mapLog ChainEvent)
        makeTimedChainIndexEvent =
            interpret (logIntoTQueue @_ @(SimulatorState t) (view logMessages))
            . reinterpret (mapLog @_ @(PABMultiAgentMsg t) EmulatorMsg)
            . reinterpret (Core.timed @EmulatorEvent')
            . reinterpret (mapLog (ChainIndexEvent (knownWallet 1)))
    delayThread (fromIntegral scSlotLength :: Millisecond)
    void
        $ makeTimedChainEvent
        $ makeTimedChainIndexEvent
        $ interpret (handleChainControl @t slotCfg)
        $ Chain.processBlock >> Chain.modifySlot succ

-- | Get the current state of the contract instance.
instanceState :: forall t. Wallet -> ContractInstanceId -> Simulation t (Contract.State t)
instanceState = Core.instanceState

-- | An STM transaction that returns the observable state of the contract instance.
observableState :: forall t. ContractInstanceId -> Simulation t (STM JSON.Value)
observableState = Core.observableState

-- | Wait until the observable state of the instance matches a predicate.
waitForState :: forall t a. (JSON.Value -> Maybe a) -> ContractInstanceId -> Simulation t a
waitForState = Core.waitForState

-- | The list of endpoints that are currently open
activeEndpoints :: forall t. ContractInstanceId -> Simulation t (STM [OpenEndpoint])
activeEndpoints = Core.activeEndpoints

-- | The final result of the instance (waits until it is available)
finalResult :: forall t. ContractInstanceId -> Simulation t (STM (Maybe JSON.Value))
finalResult = Core.finalResult

-- | Wait until the contract is done, then return
--   the error (if any)
waitUntilFinished :: forall t. ContractInstanceId -> Simulation t (Maybe JSON.Value)
waitUntilFinished = Core.waitUntilFinished

-- | Wait until the status of the transaction changes
waitForTxStatusChange :: forall t. TxId -> Simulation t TxStatus
waitForTxStatusChange = Core.waitForTxStatusChange

-- | Wait until the status of the transaction changes
waitForTxOutStatusChange :: forall t. TxOutRef -> Simulation t TxOutStatus
waitForTxOutStatusChange = Core.waitForTxOutStatusChange

-- | Wait until the endpoint becomes active.
waitForEndpoint :: forall t. ContractInstanceId -> String -> Simulation t ()
waitForEndpoint = Core.waitForEndpoint

currentSlot :: forall t. Simulation t (STM Slot)
currentSlot = Core.currentSlot

-- | Wait until the target slot number has been reached
waitUntilSlot :: forall t. Slot -> Simulation t ()
waitUntilSlot = Core.waitUntilSlot

-- | Wait for the given number of slots.
waitNSlots :: forall t. Int -> Simulation t ()
waitNSlots = Core.waitNSlots

type Simulation t a = Core.PABAction t (SimulatorState t) a

runSimulationWith :: SimulatorEffectHandlers t -> Simulation t a -> IO (Either PABError a)
runSimulationWith = Core.runPAB def

-- | Handle a 'LogMsg' effect in terms of a "larger" 'State' effect from which we have a setter.
logIntoTQueue ::
    forall s1 s2 effs.
    ( Member (Reader s2) effs
    , LastMember IO effs
    )
    => (s2 -> TQueue (LogMessage s1))
    -> LogMsg s1
    ~> Eff effs
logIntoTQueue f = \case
    LMessage w -> do
        tv <- asks f
        liftIO $ STM.atomically $ STM.writeTQueue tv w

handleChainControl ::
    forall t effs.
    ( LastMember IO effs
    , Member (Reader (SimulatorState t)) effs
    , Member (Reader BlockchainEnv) effs
    , Member (Reader Instances.InstancesState) effs
    , Member (LogMsg Chain.ChainEvent) effs
    , Member (LogMsg ChainIndexLog) effs
    )
    => SlotConfig
    -> ChainControlEffect
    ~> Eff effs
handleChainControl slotCfg = \case
    Chain.ProcessBlock -> do
        blockchainEnv <- ask @BlockchainEnv
        instancesState <- ask @Instances.InstancesState
        (txns, slot) <- runChainEffects @t @_ slotCfg ((,) <$> Chain.processBlock <*> Chain.getCurrentSlot)

        -- Adds a new tip on the chain index given the block and slot number
        runChainIndexEffects @t $ do
          currentTip <- getTip
          appendNewTipBlock currentTip txns slot

        void $ liftIO $ STM.atomically $ BlockchainEnv.processMockBlock instancesState blockchainEnv txns slot

        pure txns
    Chain.ModifySlot f -> runChainEffects @t @_ slotCfg (Chain.modifySlot f)

runChainEffects ::
    forall t a effs.
    ( Member (Reader (SimulatorState t)) effs
    , Member (LogMsg Chain.ChainEvent) effs
    , LastMember IO effs
    )
    => SlotConfig
    -> Eff (Chain.ChainEffect ': Chain.ChainControlEffect ': Chain.ChainEffs) a
    -> Eff effs a
runChainEffects slotCfg action = do
    SimulatorState{_chainState} <- ask @(SimulatorState t)
    (a, logs) <- liftIO $ STM.atomically $ do
                        oldState <- STM.readTVar _chainState
                        let ((a, newState), logs) =
                                run
                                $ runWriter @[LogMessage Chain.ChainEvent]
                                $ reinterpret @(LogMsg Chain.ChainEvent) @(Writer [LogMessage Chain.ChainEvent]) (handleLogWriter _singleton)
                                $ runState oldState
                                $ interpret Chain.handleControlChain
                                $ interpret (Chain.handleChain slotCfg) action
                        STM.writeTVar _chainState newState
                        pure (a, logs)
    traverse_ (send . LMessage) logs
    pure a

runChainIndexEffects ::
    forall t a m effs.
    ( Member (Reader (SimulatorState t)) effs
    , Member (LogMsg ChainIndexLog) effs
    , LastMember m effs
    , MonadIO m
    )
    => Eff (ChainIndexQueryEffect ': ChainIndexControlEffect ': '[State ChainIndexEmulatorState, LogMsg ChainIndexLog, Error ChainIndexError]) a
    -> Eff effs a
runChainIndexEffects action = do
    SimulatorState{_chainIndex} <- ask @(SimulatorState t)
    (a, logs) <- liftIO $ STM.atomically $ do
                    oldState <- STM.readTVar _chainIndex
                    let resultE =
                            run
                            $ runError
                            $ runWriter @[LogMessage ChainIndexLog]
                            $ reinterpret @(LogMsg ChainIndexLog) @(Writer [LogMessage ChainIndexLog]) (handleLogWriter _singleton)
                            $ runState oldState
                            $ interpret ChainIndex.handleControl
                            $ interpret ChainIndex.handleQuery action
                    case resultE of
                      Left e -> error (show e)
                      Right ((a, newState), logs) -> do
                        STM.writeTVar _chainIndex newState
                        pure (a, logs)
    traverse_ (send . LMessage) logs
    pure a

-- | Handle the 'NodeClientEffect' using the 'SimulatorState'.
handleNodeClient ::
    forall t effs.
    ( LastMember IO effs
    , Member Chain.ChainEffect effs
    , Member (Reader (SimulatorState t)) effs
    )
    => SlotConfig
    -> Wallet
    -> NodeClientEffect
    ~> Eff effs
handleNodeClient slotCfg wallet = \case
    PublishTx tx  -> do
        Chain.queueTx tx
        SimulatorState{_agentStates} <- ask @(SimulatorState t)
        liftIO $ STM.atomically $ do
            mp <- STM.readTVar _agentStates
            case Map.lookup wallet mp of
                Nothing -> do
                    let newState = initialStateFromWallet wallet & submittedFees . at (txId tx) ?~ txFee tx
                    STM.writeTVar _agentStates (Map.insert wallet newState mp)
                Just s' -> do
                    let newState = s' & submittedFees . at (txId tx) ?~ txFee tx
                    STM.writeTVar _agentStates (Map.insert wallet newState mp)
    GetClientSlot -> Chain.getCurrentSlot
    GetClientSlotConfig -> pure slotCfg

-- | Handle the 'Chain.ChainEffect' using the 'SimulatorState'.
handleChainEffect ::
    forall t effs.
    ( LastMember IO effs
    , Member (Reader (SimulatorState t)) effs
    , Member (LogMsg Chain.ChainEvent) effs
    )
    => SlotConfig
    -> Chain.ChainEffect
    ~> Eff effs
handleChainEffect slotCfg = \case
    Chain.QueueTx tx     -> runChainEffects @t slotCfg $ Chain.queueTx tx
    Chain.GetCurrentSlot -> runChainEffects @t slotCfg Chain.getCurrentSlot
    Chain.GetSlotConfig  -> pure slotCfg

handleChainIndexEffect ::
    forall t effs.
    ( LastMember IO effs
    , Member (Reader (SimulatorState t)) effs
    , Member (LogMsg ChainIndexLog) effs
    )
    => ChainIndexQueryEffect
    ~> Eff effs
handleChainIndexEffect = runChainIndexEffects @t . \case
    DatumFromHash h           -> ChainIndex.datumFromHash h
    ValidatorFromHash h       -> ChainIndex.validatorFromHash h
    MintingPolicyFromHash h   -> ChainIndex.mintingPolicyFromHash h
    StakeValidatorFromHash h  -> ChainIndex.stakeValidatorFromHash h
    RedeemerFromHash h        -> ChainIndex.redeemerFromHash h
    TxOutFromRef ref          -> ChainIndex.txOutFromRef ref
    TxFromTxId txid           -> ChainIndex.txFromTxId txid
    UtxoSetMembership ref     -> ChainIndex.utxoSetMembership ref
    UtxoSetAtAddress pq addr  -> ChainIndex.utxoSetAtAddress pq addr
    UtxoSetWithCurrency pq ac -> ChainIndex.utxoSetWithCurrency pq ac
    GetTip                    -> ChainIndex.getTip

-- | Start a thread that prints log messages to the terminal when they come in.
printLogMessages ::
    forall t.
    Pretty t
    => TQueue (LogMessage t) -- ^ log messages
    -> IO ()
printLogMessages queue = void $ forkIO $ forever $ do
    msg <- STM.atomically $ STM.readTQueue queue
    when (msg ^. logLevel >= Info) (Text.putStrLn (render msg))

-- | Call 'makeBlock' forever.
advanceClock ::
    forall t effs.
    ( LastMember IO effs
    , Member (Reader (SimulatorState t)) effs
    , Member (Reader BlockchainEnv) effs
    , Member (Reader Instances.InstancesState) effs
    , Member DelayEffect effs
    , Member TimeEffect effs
    )
    => SlotConfig
    -> Eff effs ()
advanceClock slotCfg = forever (makeBlock @t slotCfg)

-- | Handle the 'ContractStore' effect by writing the state to the
--   TVar in 'SimulatorState'
handleContractStore ::
    forall t effs.
    ( LastMember IO effs
    , Member (Reader (Core.PABEnvironment t (SimulatorState t))) effs
    , Member (Error PABError) effs
    )
    => ContractStore t
    ~> Eff effs
handleContractStore = \case
    Contract.PutState definition instanceId state -> do
        instancesTVar <- view instances <$> (Core.askUserEnv @t @(SimulatorState t))
        liftIO $ STM.atomically $ do
            let instState = SimulatorContractInstanceState{_contractDef = definition, _contractState = state}
            STM.modifyTVar instancesTVar (set (at instanceId) (Just instState))
    Contract.GetState instanceId -> do
        instancesTVar <- view instances <$> (Core.askUserEnv @t @(SimulatorState t))
        result <- preview (at instanceId . _Just . contractState) <$> liftIO (STM.readTVarIO instancesTVar)
        case result of
            Just s  -> pure s
            Nothing -> throwError (ContractInstanceNotFound instanceId)
    Contract.GetContracts _ -> do
        instancesTVar <- view instances <$> (Core.askUserEnv @t @(SimulatorState t))
        fmap _contractDef <$> liftIO (STM.readTVarIO instancesTVar)
    Contract.PutStartInstance{} -> pure ()
    Contract.PutStopInstance{} -> pure ()

render :: forall a. Pretty a => a -> Text
render = Render.renderStrict . layoutPretty defaultLayoutOptions . pretty


-- | Statistics about the transactions that have been validated by the emulated
--   node.
data TxCounts =
    TxCounts
        { _txValidated :: Int
        -- ^ How many transactions were checked and added to the ledger
        , _txMemPool   :: Int
        -- ^ How many transactions remain in the mempool of the emulated node
        } deriving (Eq, Ord, Show)

makeLenses ''TxCounts

-- | Get the 'TxCounts' of the emulated blockchain
txCounts :: forall t. Simulation t TxCounts
txCounts = txCountsSTM >>= liftIO . STM.atomically

-- | Get an STM transaction with the 'TxCounts' of the emulated blockchain
txCountsSTM :: forall t. Simulation t (STM TxCounts)
txCountsSTM = do
    SimulatorState{_chainState} <- Core.askUserEnv @t @(SimulatorState t)
    return $ do
        Chain.ChainState{Chain._chainNewestFirst, Chain._txPool} <- STM.readTVar _chainState
        pure
            $ TxCounts
                { _txValidated = sum (length <$> _chainNewestFirst)
                , _txMemPool   = length _txPool
                }

-- | Wait until at least the given number of valid transactions are on the simulated blockchain.
waitForValidatedTxCount :: forall t. Int -> Simulation t ()
waitForValidatedTxCount i = do
    counts <- txCountsSTM
    liftIO $ STM.atomically $ do
        TxCounts{_txValidated} <- counts
        guard (_txValidated >= i)

-- | The set of all active contracts.
activeContracts :: forall t. Simulation t (Set ContractInstanceId)
activeContracts = Core.activeContracts

-- | The total value currently at an address
valueAtSTM :: forall t. Address -> Simulation t (STM Value)
valueAtSTM address = do
    SimulatorState{_chainState} <- Core.askUserEnv @t @(SimulatorState t)
    pure $ do
        Chain.ChainState{Chain._index=UtxoIndex.UtxoIndex mp} <- STM.readTVar _chainState
        pure $ foldMap txOutValue $ filter (\TxOut{txOutAddress} -> txOutAddress == address) $ fmap snd $ Map.toList mp

-- | The total value currently at an address
valueAt :: forall t. Address -> Simulation t Value
valueAt address = do
    stm <- valueAtSTM address
    liftIO $ STM.atomically stm

-- | The fees paid by the wallet.
walletFees :: forall t. Wallet -> Simulation t Value
walletFees wallet = succeededFees <$> walletSubmittedFees <*> blockchain
    where
        succeededFees :: Map TxId Value -> Blockchain -> Value
        succeededFees submitted = foldMap . foldMap $ fold . (submitted Map.!?) . eitherTx txId txId
        walletSubmittedFees = do
            SimulatorState{_agentStates} <- Core.askUserEnv @t @(SimulatorState t)
            result <- liftIO $ STM.atomically $ do
                mp <- STM.readTVar _agentStates
                pure $ Map.lookup wallet mp
            case result of
                Nothing -> throwError $ WalletNotFound wallet
                Just s  -> pure (_submittedFees s)

-- | The entire chain (newest transactions first)
blockchain :: forall t. Simulation t Blockchain
blockchain = do
    SimulatorState{_chainState} <- Core.askUserEnv @t @(SimulatorState t)
    Chain.ChainState{Chain._chainNewestFirst} <- liftIO $ STM.readTVarIO _chainState
    pure _chainNewestFirst

handleAgentThread ::
    forall t a.
    Wallet
    -> Eff (Core.ContractInstanceEffects t (SimulatorState t) '[IO]) a
    -> Simulation t a
handleAgentThread = Core.handleAgentThread

-- | Stop the instance.
stopInstance :: forall t. ContractInstanceId -> Simulation t ()
stopInstance = Core.stopInstance

-- | The 'Activity' state of the instance
instanceActivity :: forall t. ContractInstanceId -> Simulation t Activity
instanceActivity = Core.instanceActivity

-- | Create a new wallet with a random key, give it some funds
--   and add it to the list of simulated wallets.
addWallet :: forall t. Simulation t (Wallet,PubKeyHash)
addWallet = do
    SimulatorState{_agentStates} <- Core.askUserEnv @t @(SimulatorState t)
    mockWallet <- MockWallet.newWallet
    void $ liftIO $ STM.atomically $ do
        currentWallets <- STM.readTVar _agentStates
        let newWallets = currentWallets & at (Wallet.toMockWallet mockWallet) ?~ AgentState (Wallet.fromMockWallet mockWallet) mempty
        STM.writeTVar _agentStates newWallets
    _ <- handleAgentThread (knownWallet 2)
            $ Modify.wrapError WalletError
            $ MockWallet.distributeNewWalletFunds (CW.pubKeyHash mockWallet)
    pure (Wallet.toMockWallet mockWallet, CW.pubKeyHash mockWallet)


-- | Retrieve the balances of all the entities in the simulator.
currentBalances :: forall t. Simulation t (Map.Map Wallet.Entity Value)
currentBalances = do
  SimulatorState{_chainState, _agentStates} <- Core.askUserEnv @t @(SimulatorState t)
  liftIO $ STM.atomically $ do
    currentWallets <- STM.readTVar _agentStates
    chainState <- STM.readTVar _chainState
    return $ Wallet.balances chainState (_walletState <$> currentWallets)

-- | Write the 'balances' out to the log.
logBalances :: forall t effs. Member (LogMsg (PABMultiAgentMsg t)) effs
            => Map.Map Wallet.Entity Value
            -> Eff effs ()
logBalances bs = do
    forM_ (Map.toList bs) $ \(e, v) -> do
        logString @t $ show e <> ": "
        forM_ (flattenValue v) $ \(cs, tn, a) ->
            logString @t $ "    {" <> show cs <> ", " <> show tn <> "}: " <> show a

-- | Log some output to the console
logString :: forall t effs. Member (LogMsg (PABMultiAgentMsg t)) effs => String -> Eff effs ()
logString = logInfo @(PABMultiAgentMsg t) . UserLog . Text.pack

-- | Make a payment from one wallet to another
payToWallet :: forall t. Wallet -> Wallet -> Value -> Simulation t CardanoTx
payToWallet source target = payToPublicKeyHash source (Emulator.walletPubKeyHash target)

-- | Make a payment from one wallet to a public key address
payToPublicKeyHash :: forall t. Wallet -> PubKeyHash -> Value -> Simulation t CardanoTx
payToPublicKeyHash source target amount =
    handleAgentThread source
        $ flip (handleError @WAPI.WalletAPIError) (throwError . WalletError)
        $ WAPI.payToPublicKeyHash WAPI.defaultSlotRange amount target
