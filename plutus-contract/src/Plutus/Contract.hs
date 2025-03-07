{-# LANGUAGE ConstraintKinds    #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE MonoLocalBinds     #-}
module Plutus.Contract(
      Contract(..)
    , ContractError(..)
    , AsContractError(..)
    , IsContract(..)
    , (>>)
    , throwError
    , handleError
    , mapError
    , runError
    -- * Select
    , Promise
    , awaitPromise
    , promiseMap
    , promiseBind
    , both
    , selectEither
    , select
    , selectList
    , never
    -- * Dealing with time
    , Request.awaitSlot
    , Request.isSlot
    , Request.currentSlot
    , Request.waitNSlots
    , Request.awaitTime
    , Request.isTime
    , Request.currentTime
    , Request.waitNMilliSeconds
    -- * Endpoints
    , Request.HasEndpoint
    , Request.EndpointDescription(..)
    , Request.Endpoint
    , Request.endpoint
    , Request.handleEndpoint
    , Request.endpointWithMeta
    , Schema.EmptySchema
    -- * Blockchain events
    , Request.watchAddressUntilSlot
    , Request.watchAddressUntilTime
    , Request.fundsAtAddressGt
    , Request.fundsAtAddressGeq
    , Request.awaitUtxoSpent
    , Request.utxoIsSpent
    , Request.awaitUtxoProduced
    , Request.utxoIsProduced
    -- * Chain index requests
    , Request.datumFromHash
    , Request.validatorFromHash
    , Request.mintingPolicyFromHash
    , Request.stakeValidatorFromHash
    , Request.txOutFromRef
    , Request.txFromTxId
    , Request.utxoRefMembership
    , Request.utxoRefsAt
    , Request.utxoRefsWithCurrency
    , Request.utxosAt
    , Request.utxosTxOutTxAt
    , Request.utxosTxOutTxFromTx
    , Request.getTip
    -- * Wallet's own public key
    , Request.ownPubKeyHash
    -- * Contract instance Id
    , Wallet.Types.ContractInstanceId
    , Request.ownInstanceId
    -- * Notifications
    , tell
    -- * Transactions
    , WalletAPIError
    , Request.submitTx
    , Request.submitTxConfirmed
    , Request.submitTxConstraints
    , Request.submitTxConstraintsSpending
    , Request.submitTxConstraintsWith
    , Request.submitUnbalancedTx
    , Request.submitBalancedTx
    , Request.balanceTx
    , Request.mkTxConstraints
    -- ** Creating transactions
    , module Tx
    -- ** Tx confirmation
    , Request.awaitTxConfirmed
    , Request.awaitTxStatusChange
    , Request.isTxConfirmed
    -- ** Tx output confirmation
    , Request.awaitTxOutStatusChange
    -- * Checkpoints
    , checkpoint
    , checkpointLoop
    , AsCheckpointError(..)
    , CheckpointError(..)
    -- * Logging
    , logDebug
    , logInfo
    , logWarn
    , logError
    -- * Row-related things
    , HasType
    , ContractRow
    , type (.\/)
    , type Empty
    ) where

import Data.Aeson (ToJSON (toJSON))
import Data.Row

import Plutus.Contract.Request (ContractRow)
import Plutus.Contract.Request qualified as Request
import Plutus.Contract.Schema qualified as Schema
import Plutus.Contract.Typed.Tx as Tx
import Plutus.Contract.Types (AsCheckpointError (..), AsContractError (..), CheckpointError (..), Contract (..),
                              ContractError (..), IsContract (..), Promise (..), checkpoint, checkpointLoop,
                              handleError, mapError, never, promiseBind, promiseMap, runError, select, selectEither,
                              selectList, throwError)

import Control.Monad.Freer.Extras.Log qualified as L
import Control.Monad.Freer.Writer qualified as W
import Data.Functor.Apply (liftF2)
import Prelude
import Wallet.API (WalletAPIError)
import Wallet.Types qualified

-- | Execute both contracts in any order
both :: Promise w s e a -> Promise w s e b -> Promise w s e (a, b)
both a b = liftF2 (,) a b `select` liftF2 (flip (,)) b a

-- | Log a message at the 'Debug' level
logDebug :: ToJSON a => a -> Contract w s e ()
logDebug = Contract . L.logDebug . toJSON

-- | Log a message at the 'Info' level
logInfo :: ToJSON a => a -> Contract w s e ()
logInfo = Contract . L.logInfo . toJSON

-- | Log a message at the 'Warning' level
logWarn :: ToJSON a => a -> Contract w s e ()
logWarn = Contract . L.logWarn . toJSON

-- | Log a message at the 'Error' level
logError :: ToJSON a => a -> Contract w s e ()
logError = Contract . L.logError . toJSON

-- | Update the contract's accumulating state @w@
tell :: w -> Contract w s e ()
tell = Contract . W.tell
