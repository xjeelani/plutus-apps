{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators    #-}

module Cardano.Wallet.Mock.Client where

import Cardano.Wallet.Mock.API (API)
import Cardano.Wallet.Mock.Types (WalletInfo (..))
import Control.Monad (void)
import Control.Monad.Freer
import Control.Monad.Freer.Error (Error, throwError)
import Control.Monad.Freer.Reader (Reader, ask)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Proxy (Proxy (Proxy))
import Ledger (Value)
import Ledger.Constraints.OffChain (UnbalancedTx)
import Ledger.Tx (Tx)
import Servant ((:<|>) (..))
import Servant.Client (ClientEnv, ClientError, ClientM, client, runClientM)
import Wallet.Effects (WalletEffect (..))
import Wallet.Emulator.Error (WalletAPIError)
import Wallet.Emulator.Wallet (Wallet (..), WalletId)

createWallet :: ClientM WalletInfo
submitTxn :: Wallet -> Tx -> ClientM ()
ownPublicKey :: Wallet -> ClientM WalletInfo
balanceTx :: Wallet -> UnbalancedTx -> ClientM (Either WalletAPIError Tx)
totalFunds :: Wallet -> ClientM Value
sign :: Wallet -> Tx -> ClientM Tx
(createWallet, submitTxn, ownPublicKey, balanceTx, totalFunds, sign) =
  ( createWallet_
  , \(Wallet wid) tx -> void (submitTxn_ wid tx)
  , ownPublicKey_ . getWalletId
  , balanceTx_ . getWalletId
  , totalFunds_ . getWalletId
  , sign_ . getWalletId)
  where
    ( createWallet_
      :<|> (submitTxn_
      :<|> ownPublicKey_
      :<|> balanceTx_
      :<|> totalFunds_
      :<|> sign_)) = client (Proxy @(API WalletId))

handleWalletClient ::
  forall m effs.
  ( LastMember m effs
  , MonadIO m
  , Member (Error ClientError) effs
  , Member (Reader ClientEnv) effs
  )
  => Wallet
  -> WalletEffect
  ~> Eff effs
handleWalletClient wallet event = do
    clientEnv <- ask @ClientEnv
    let
        runClient :: forall a. ClientM a -> Eff effs a
        runClient a = (sendM $ liftIO $ runClientM a clientEnv) >>= either throwError pure
    case event of
        SubmitTxn (Left _)            -> error "Cardano.Wallet.Mock.Client: Expecting a mock tx, not an Alonzo tx when submitting it."
        SubmitTxn (Right tx)          -> runClient (submitTxn wallet tx)
        OwnPubKeyHash                 -> wiPubKeyHash <$> runClient (ownPublicKey wallet)
        BalanceTx utx                 -> runClient (fmap (fmap Right) $ balanceTx wallet utx)
        WalletAddSignature (Left _)   -> error "Cardano.Wallet.Mock.Client: Expection a mock tx, not an Alonzo tx when adding a signature."
        WalletAddSignature (Right tx) -> runClient $ fmap Right $ sign wallet tx
        TotalFunds                    -> runClient (totalFunds wallet)
