{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeApplications   #-}
{-# LANGUAGE TypeFamilies       #-}
{-# LANGUAGE TypeOperators      #-}
-- | Two sample that unlock some funds by presenting the credentials.
--   * 'subscribeSTO' uses the credential to participate in an STO
--   * 'unlockExchange' uses the credential to take ownership of funds that
--     were locked by an exchange.
module Plutus.Contracts.Prism.Unlock(
    -- * STO
    STOSubscriber(..)
    , STOSubscriberSchema
    , subscribeSTO
    -- * Exchange
    , UnlockExchangeSchema
    , unlockExchange
    -- * Errors etc.
    , UnlockError(..)
    ) where

import Control.Lens (makeClassyPrisms)
import Control.Monad (forever)
import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)
import Ledger.Ada qualified as Ada
import Ledger.Constraints (ScriptLookups, SomeLookupsAndConstraints (..), TxConstraints (..))
import Ledger.Constraints qualified as Constraints
import Ledger.Crypto (PubKeyHash)
import Ledger.Tx (getCardanoTxId)
import Ledger.Value (TokenName)
import Plutus.Contract
import Plutus.Contract.StateMachine (InvalidTransition, SMContractError, StateMachine, StateMachineTransition (..))
import Plutus.Contract.StateMachine qualified as SM
import Plutus.Contracts.Prism.Credential (Credential)
import Plutus.Contracts.Prism.Credential qualified as Credential
import Plutus.Contracts.Prism.STO (STOData (..))
import Plutus.Contracts.Prism.STO qualified as STO
import Plutus.Contracts.Prism.StateMachine (IDAction (PresentCredential), IDState, UserCredential (..))
import Plutus.Contracts.Prism.StateMachine qualified as StateMachine
import Plutus.Contracts.TokenAccount (TokenAccountError)
import Plutus.Contracts.TokenAccount qualified as TokenAccount
import Prelude as Haskell
import Schema (ToSchema)

data STOSubscriber =
    STOSubscriber
        { wCredential   :: Credential
        , wSTOIssuer    :: PubKeyHash
        , wSTOTokenName :: TokenName
        , wSTOAmount    :: Integer
        }
    deriving stock (Generic, Haskell.Eq, Haskell.Show)
    deriving anyclass (ToJSON, FromJSON, ToSchema)

type STOSubscriberSchema = Endpoint "sto" STOSubscriber

-- | Obtain a token from the credential manager app,
--   then participate in the STO
subscribeSTO :: forall w s.
    ( HasEndpoint "sto" STOSubscriber s
    )
    => Contract w s UnlockError ()
subscribeSTO = forever $ handleError (const $ return ()) $ awaitPromise $
    endpoint @"sto" $ \STOSubscriber{wCredential, wSTOIssuer, wSTOTokenName, wSTOAmount} -> do
        (credConstraints, credLookups) <- obtainCredentialTokenData wCredential
        let stoData =
                STOData
                    { stoIssuer = wSTOIssuer
                    , stoTokenName = wSTOTokenName
                    , stoCredentialToken = Credential.token wCredential
                    }
            stoCoins = STO.coins stoData wSTOAmount
            constraints =
                Constraints.mustMintValue stoCoins
                <> Constraints.mustPayToPubKey wSTOIssuer (Ada.lovelaceValueOf wSTOAmount)
                <> credConstraints
            lookups =
                Constraints.mintingPolicy (STO.policy stoData)
                <> credLookups
        mapError WithdrawTxError
            $ submitTxConstraintsWith lookups constraints >>= awaitTxConfirmed . getCardanoTxId

type UnlockExchangeSchema = Endpoint "unlock from exchange" Credential

-- | Obtain a token from the credential manager app,
--   then use it to unlock funds that were locked by an exchange.
unlockExchange :: forall w s.
    ( HasEndpoint "unlock from exchange" Credential s
    )
    => Contract w s UnlockError ()
unlockExchange = awaitPromise $ endpoint @"unlock from exchange" $ \credential -> do
    ownPK <- mapError WithdrawPkError ownPubKeyHash
    (credConstraints, credLookups) <- obtainCredentialTokenData credential
    (accConstraints, accLookups) <-
        mapError UnlockExchangeTokenAccError
        $ TokenAccount.redeemTx (Credential.tokenAccount credential) ownPK
    case Constraints.mkSomeTx [SomeLookupsAndConstraints credLookups credConstraints, SomeLookupsAndConstraints accLookups accConstraints] of
        Left mkTxErr -> throwError (UnlockMkTxError mkTxErr)
        Right utx -> mapError WithdrawTxError $ do
            tx <- submitUnbalancedTx utx
            awaitTxConfirmed (getCardanoTxId tx)

-- | Get the constraints and script lookups that are needed to construct a
--   transaction that presents the 'Credential'
obtainCredentialTokenData :: forall w s.
    Credential
    -> Contract w s UnlockError (TxConstraints IDAction IDState, ScriptLookups (StateMachine IDState IDAction))
obtainCredentialTokenData credential = do
    -- credentialManager <- mapError WithdrawEndpointError $ endpoint @"credential manager"
    userCredential <- mapError WithdrawPkError $
        UserCredential
            <$> ownPubKeyHash
            <*> pure credential
            <*> pure (Credential.token credential)

    -- Calls the 'PresentCredential' step on the state machine instance and returns the constraints
    -- needed to construct a transaction that presents the token.
    let theClient = StateMachine.machineClient (StateMachine.typedValidator userCredential) userCredential
    t <- mapError GetCredentialStateMachineError $ SM.mkStep theClient PresentCredential
    case t of
        Left e -> throwError $ GetCredentialTransitionError e
        Right StateMachineTransition{smtConstraints=cons, smtLookups=lookups} ->
            pure (cons, lookups)

---
-- logs / error
---

data UnlockError =
    WithdrawEndpointError ContractError
    | WithdrawTxError ContractError
    | WithdrawPkError ContractError
    | GetCredentialStateMachineError SMContractError
    | GetCredentialTransitionError (InvalidTransition IDState IDAction)
    | UnlockExchangeTokenAccError TokenAccountError
    | UnlockMkTxError Constraints.MkTxError
    deriving stock (Generic, Haskell.Eq, Haskell.Show)
    deriving anyclass (ToJSON, FromJSON)

makeClassyPrisms ''UnlockError

instance AsContractError UnlockError where
    _ContractError = _WithdrawEndpointError . _ContractError
