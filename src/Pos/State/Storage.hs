{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE Rank2Types             #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE ViewPatterns           #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

-- | Storage with node local state which should be persistent.

module Pos.State.Storage
       (
         Storage
       , storageFromUtxo

       , Query
       , getBlock
       , getHeadBlock
       , getGlobalSscPayload
       , getLeaders
       , getLocalTxs
       , getLocalSscPayload
       , getOurShares
       , getParticipants
       , getThreshold
       , getToken
       , mayBlockBeUseful

       , ProcessBlockRes (..)
       , ProcessTxRes (..)

       , Update
       , createNewBlock
       , processBlock
       , processNewSlot
       , processSscMessage
       , processTx
       , setToken
       ) where

import           Control.Lens            (makeClassy, use, view, (.=), (^.))
import           Control.Monad.TM        ((.=<<.))
import           Data.Acid               ()
import           Data.Default            (Default, def)
import           Data.List.NonEmpty      (NonEmpty ((:|)))
import           Data.SafeCopy           (SafeCopy (..), contain, safeGet, safePut)
import           Data.Tagged             (untag)
import           Formatting              (build, sformat, (%))
import           Serokell.AcidState      ()
import           Serokell.Util           (VerificationRes (..))
import           Universum

import           Pos.Constants           (k)
import           Pos.Crypto              (PublicKey, SecretKey, Share, Threshold,
                                          VssKeyPair, VssPublicKey)
import           Pos.Genesis             (genesisUtxo)
import           Pos.Ssc.Class.Storage   (HasSscStorage (..), SscStorageClass (..))
import           Pos.Ssc.Class.Types     (SscTypes (..))
import           Pos.State.Storage.Block (BlockStorage, HasBlockStorage (blockStorage),
                                          blkCleanUp, blkCreateGenesisBlock,
                                          blkCreateNewBlock, blkProcessBlock, blkRollback,
                                          blkSetHead, getBlock, getHeadBlock, getLeaders,
                                          getSlotDepth, mayBlockBeUseful, mkBlockStorage)
import           Pos.State.Storage.Tx    (HasTxStorage (txStorage), TxStorage,
                                          getLocalTxs, getUtxoByDepth, processTx,
                                          txApplyBlocks, txRollback, txStorageFromUtxo,
                                          txVerifyBlocks)
import           Pos.State.Storage.Types (AltChain, ProcessBlockRes (..),
                                          ProcessTxRes (..), mkPBRabort)
import           Pos.Types               (Block, EpochIndex, GenesisBlock, MainBlock,
                                          SlotId (..), SlotLeaders, Utxo, blockMpc,
                                          blockSlot, blockTxs, epochIndexL, flattenSlotId,
                                          gbHeader, headerHashG, unflattenSlotId,
                                          verifyTxAlone)
import           Pos.Util                (readerToState, _neLast)

type Query  ssc a = forall m . (SscTypes ssc, MonadReader (Storage ssc) m) => m a
type Update ssc a = forall m . (SscTypes ssc, MonadState (Storage ssc) m) => m a

data Storage ssc = Storage
    { -- | State of MPC.
      __mpcStorage   :: !(SscStorage ssc)
    , -- | Transactions part of /static-state/.
      __txStorage    :: !TxStorage
    , -- | Blockchain part of /static-state/.
      __blockStorage :: !(BlockStorage ssc)
    , -- | Id of last seen slot.
      _slotId        :: !SlotId
    }

makeClassy ''Storage
instance SscTypes ssc => SafeCopy (Storage ssc) where
    putCopy Storage {..} =
        contain $
        do safePut __mpcStorage
           safePut __txStorage
           safePut __blockStorage
           safePut _slotId
    getCopy =
        contain $
        do __mpcStorage <- safeGet
           __txStorage <- safeGet
           __blockStorage <- safeGet
           _slotId <- safeGet
           return $! Storage {..}

instance HasSscStorage ssc (Storage ssc) where
    sscStorage = _mpcStorage
instance HasTxStorage (Storage ssc) where
    txStorage = _txStorage
instance HasBlockStorage (Storage ssc) ssc where
    blockStorage = _blockStorage

instance (SscTypes ssc, Default (SscStorage ssc)) => Default (Storage ssc) where
    def = storageFromUtxo $ genesisUtxo def

-- | Create default storage with specified utxo
storageFromUtxo
    :: (SscTypes ssc, Default (SscStorage ssc))
    => Utxo -> (Storage ssc)
storageFromUtxo u =
    Storage
    { __mpcStorage = def
    , __txStorage = txStorageFromUtxo u
    , __blockStorage = mkBlockStorage u
    , _slotId = unflattenSlotId 0
    }

getHeadSlot :: Query ssc (Either EpochIndex SlotId)
getHeadSlot = bimap (view epochIndexL) (view blockSlot) <$> getHeadBlock

getLocalSscPayload
    :: forall ssc.
       SscStorageClass ssc
    => SlotId -> Query ssc (SscPayload ssc)
getLocalSscPayload = sscGetLocalPayload @ ssc

getGlobalSscPayload
    :: forall ssc.
       SscStorageClass ssc
    => Query ssc (SscPayload ssc)
getGlobalSscPayload = sscGetGlobalPayload @ ssc

getToken
    :: forall ssc.
       SscStorageClass ssc
    => Query ssc (Maybe (SscToken ssc))
getToken = sscGetToken @ ssc

getOurShares
    :: forall ssc.
       SscStorageClass ssc
    => VssKeyPair -- ^ Our VSS key
    -> Integer -- ^ Random generator seed (needed for 'decryptShare')
    -> Query ssc (HashMap PublicKey Share)
getOurShares = sscGetOurShares @ ssc

-- | Create a new block on top of best chain if possible.
-- Block can be created if:
-- • we know genesis block for epoch from given SlotId
-- • last known block is not more than k slots away from
-- given SlotId
createNewBlock
    :: SscStorageClass ssc
    => SecretKey -> SlotId -> Update ssc (Maybe (MainBlock ssc))
createNewBlock sk sId = do
    ifM (readerToState (canCreateBlock sId))
        (Just <$> createNewBlockDo sk sId)
        (pure Nothing)

createNewBlockDo
    :: forall ssc.
       SscStorageClass ssc
    => SecretKey -> SlotId -> Update ssc (MainBlock ssc)
createNewBlockDo sk sId = do
    txs <- readerToState $ toList <$> getLocalTxs
    mpcData <- readerToState (sscGetLocalPayload @ssc sId)
    blk <- blkCreateNewBlock sk sId txs mpcData
    let blocks = Right blk :| []
    sscApplyBlocks blocks
    blk <$ txApplyBlocks blocks

canCreateBlock :: SlotId -> Query ssc Bool
canCreateBlock sId = do
    maxSlotId <- canCreateBlockMax
    --identity $! traceM $ "[~~~~~~] canCreateBlock: slotId=" <> pretty slotId <> " < max=" <> pretty max <> " = " <> show (flattenSlotId slotId < flattenSlotId max)
    return (sId <= maxSlotId)
  where
    canCreateBlockMax = addKSafe . either (`SlotId` 0) identity <$> getHeadSlot
    addKSafe si = si {siSlot = min (6 * k - 1) (siSlot si + k)}

-- | Do all necessary changes when a block is received.
processBlock :: SscStorageClass ssc
    => SlotId -> Block ssc -> Update ssc (ProcessBlockRes ssc)
processBlock curSlotId blk = do
    -- TODO: I guess these checks should be part of block verification actually.
    let verifyMpc mainBlk =
            untag sscVerifyPayload (mainBlk ^. gbHeader) (mainBlk ^. blockMpc)
    let mpcRes = either (const mempty) verifyMpc blk
    let txs =
            case blk of
                Left _        -> []
                Right mainBlk -> toList $ mainBlk ^. blockTxs
    let txRes = foldMap verifyTxAlone txs
    case mpcRes <> txRes of
        VerSuccess        -> processBlockDo curSlotId blk
        VerFailure errors -> return $ mkPBRabort errors

processBlockDo
    :: forall ssc.
       SscStorageClass ssc
    => SlotId -> Block ssc -> Update ssc (ProcessBlockRes ssc)
processBlockDo curSlotId blk = do
    r <- blkProcessBlock curSlotId blk
    case r of
        PBRgood (toRollback, chain) -> do
            mpcRes <- readerToState $ (sscVerifyBlocks @ ssc) toRollback chain
            txRes <- readerToState $ txVerifyBlocks toRollback chain
            case mpcRes <> txRes of
                VerSuccess        -> processBlockFinally toRollback chain
                VerFailure errors -> return $ mkPBRabort errors
        -- if we need block which we already know, we just use it
        PBRmore h ->
            maybe (pure r) (processBlockDo curSlotId) =<<
            readerToState (getBlock h)
        _ -> return r

-- At this point all checks have been passed and we know that we can
-- adopt this AltChain.
processBlockFinally :: forall ssc . SscStorageClass ssc => Word
                    -> AltChain ssc
                    -> Update ssc (ProcessBlockRes ssc)
processBlockFinally toRollback blocks = do
    (sscRollback @ ssc) toRollback
    (sscApplyBlocks @ ssc) blocks
    txRollback toRollback
    txApplyBlocks blocks
    blkRollback toRollback
    blkSetHead (blocks ^. _neLast . headerHashG)
    knownEpoch <- use (slotId . epochIndexL)
    -- When we adopt alternative chain, it may revert genesis block
    -- already created for current epoch. And we will be in situation
    -- where best chain doesn't have genesis block for current epoch.
    -- If then we need to create block in current epoch, it will be
    -- definitely invalid. To prevent it we create genesis block after
    -- possible revert. Note that createGenesisBlock function will
    -- create block only for epoch which is one more than epoch of
    -- head, so we don't perform such check here.  Also note that it
    -- is not strictly necessary, because we have `canCreateBlock`
    -- which prevents us from creating block when we are not ready,
    -- but it is still good as an optimization. Even if later we see
    -- that there were other valid blocks in old epoch, we will
    -- replace chain and everything will be fine.
    _ <- createGenesisBlock knownEpoch
    return $ PBRgood (toRollback, blocks)

-- | Do all necessary changes when new slot starts.
processNewSlot
    :: forall ssc.
       SscStorageClass ssc
    => SlotId -> Update ssc (Maybe (GenesisBlock ssc))
processNewSlot sId = do
    knownSlot <- use slotId
    if sId > knownSlot
       then processNewSlotDo sId
       else pure Nothing

processNewSlotDo
    :: forall ssc .
       SscStorageClass ssc
    => SlotId -> Update ssc (Maybe (GenesisBlock ssc))
processNewSlotDo sId@SlotId {..} = do
    slotId .= sId
    mGenBlock <-
      if siSlot == 0
         then (createGenesisBlock @ ssc) siEpoch
         else pure Nothing
    blkCleanUp sId
    (sscPrepareToNewSlot @ ssc) sId $> mGenBlock

-- We create genesis block for i-th epoch when head of currently known
-- best chain is MainBlock corresponding to one of last `k` slots of
-- (i - 1)-th epoch. Main check is that epoch is (last stored epoch +
-- 1), but we also don't want to create genesis block on top of blocks
-- from previous epoch which are not from last k slots, because it's
-- practically impossible for them to be valid.
shouldCreateGenesisBlock :: EpochIndex -> Query ssc Bool
-- Genesis block for 0-th epoch is hardcoded.
shouldCreateGenesisBlock 0 = pure False
shouldCreateGenesisBlock epoch =
    doCheck . either (`SlotId` 0) identity <$> getHeadSlot
  where
    doCheck SlotId {..} = siEpoch == epoch - 1 && siSlot >= 5 * k

createGenesisBlock
    :: forall ssc.
       SscStorageClass ssc
    => EpochIndex -> Update ssc (Maybe (GenesisBlock ssc))
createGenesisBlock epoch = do
    --readerToState getHeadSlot >>= \hs ->
    --  identity $! traceM $ "[~~~~~~] createGenesisBlock: epoch="
    --                       <> pretty epoch <> ", headSlot=" <> pretty (either (`SlotId` 0) identity hs)
    ifM (readerToState $ shouldCreateGenesisBlock epoch)
        (Just <$> createGenesisBlockDo epoch)
        (pure Nothing)

createGenesisBlockDo
    :: forall ssc.
       SscStorageClass ssc
    => EpochIndex -> Update ssc (GenesisBlock ssc)
createGenesisBlockDo epoch = do
    --traceMpcLastVer
    leaders <- readerToState $ calculateLeaders epoch
    genBlock <- blkCreateGenesisBlock epoch leaders
    -- Genesis block contains no transactions,
    --    so we should update only MPC
    sscApplyBlocks $ Left genBlock :| []
    pure genBlock

calculateLeaders
    :: forall ssc.
       SscStorageClass ssc
    => EpochIndex -> Query ssc SlotLeaders
calculateLeaders epoch = do
    depth <- fromMaybe onErrorGetDepth <$> getMpcCrucialDepth epoch
    utxo <- fromMaybe onErrorGetUtxo <$> getUtxoByDepth depth
    -- TODO: overall 'calculateLeadersDo' gets utxo twice, could be optimised
    threshold <- fromMaybe onErrorGetThreshold <$> getThreshold epoch
    either onErrorCalcLeaders identity <$> (sscCalculateLeaders @ ssc) epoch utxo threshold
  where
    onErrorGetDepth =
        panic "Depth of MPC crucial slot isn't reasonable"
    onErrorGetUtxo =
        panic "Failed to get utxo necessary for leaders calculation"
    onErrorGetThreshold =
        panic "Failed to get threshold necessary for leaders calculation"
    onErrorCalcLeaders e =
        panic (sformat ("Leaders calculation reported error: " % build) e)

-- | Get keys of nodes participating in an epoch. A node participates if,
-- when there were 'k' slots left before the end of the previous epoch, both
-- of these were true:
--
--   1. It was a stakeholder.
--   2. It had already sent us its VSS key by that time.
getParticipants
    :: forall ssc.
       SscStorageClass ssc
    => EpochIndex -> Query ssc (Maybe (NonEmpty VssPublicKey))
getParticipants epoch = do
    mDepth <- getMpcCrucialDepth epoch
    mUtxo <- getUtxoByDepth .=<<. mDepth
    case (,) <$> mDepth <*> mUtxo of
        Nothing            -> return Nothing
        Just (depth, utxo) -> (sscGetParticipants @ ssc) depth utxo

-- slot such that data after it is used for MPC in given epoch
mpcCrucialSlot :: EpochIndex -> SlotId
mpcCrucialSlot 0     = SlotId {siEpoch = 0, siSlot = 0}
mpcCrucialSlot epoch = SlotId {siEpoch = epoch - 1, siSlot = 5 * k - 1}

getMpcCrucialDepth :: EpochIndex -> Query ssc (Maybe Word)
getMpcCrucialDepth epoch = do
    let crucialSlot = mpcCrucialSlot epoch
    (depth, slot) <- getSlotDepth crucialSlot
    if flattenSlotId slot + 2 * k < flattenSlotId (SlotId epoch 0)
        then return Nothing
        else return (Just depth)

getThreshold :: forall ssc . SscStorageClass ssc => EpochIndex -> Query ssc (Maybe Threshold)
getThreshold epoch = do
    fmap getThresholdImpl <$> (getParticipants @ ssc) epoch
  where
    getThresholdImpl (length -> len) = fromIntegral $ len `div` 2 + len `mod` 2

processSscMessage
    :: forall ssc.
       SscStorageClass ssc
    => SscMessage ssc -> Update ssc (Maybe (SscMessage ssc))
processSscMessage = sscProcessMessage @ ssc

setToken
    :: forall ssc.
       SscStorageClass ssc
    => SscToken ssc -> Update ssc ()
setToken = sscSetToken @ ssc
