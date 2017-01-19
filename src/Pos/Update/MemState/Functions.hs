-- | Functions which work in MonadUSMem.

module Pos.Update.MemState.Functions
       ( withUSLock
       , modifyMemPool
       ) where

import qualified Control.Concurrent.Lock      as Lock
import           Control.Monad.Catch          (MonadMask, bracket_)
import qualified Data.HashMap.Strict          as HM
import           Universum

import           Pos.Crypto                   (hash)
import           Pos.Update.Core.Types        (UpdatePayload (..), UpdateVote (..))
import           Pos.Update.MemState.Class    (MonadUSMem (askUSMemVar))
import           Pos.Update.MemState.MemState (MemVar (..))
import           Pos.Update.MemState.Types    (MemPool (..))
import           Pos.Update.Poll.Types        (PollModifier (..), psProposal, psVotes)

withUSLock
    :: (MonadUSMem m, MonadIO m, MonadMask m)
    => m a -> m a
withUSLock action = do
    lock <- mvLock <$> askUSMemVar
    bracket_ (liftIO $ Lock.acquire lock) (liftIO $ Lock.release lock) action

modifyMemPool :: UpdatePayload -> PollModifier -> MemPool -> MemPool
modifyMemPool UpdatePayload {..} PollModifier{..} =
     addModifiers . delModifiers . addProposal upProposal
  where
    delModifiers MemPool{..} = MemPool
        (foldr' HM.delete mpProposals pmDelActiveProps)
        (foldr' HM.delete mpLocalVotes pmDelActiveProps)
    addModifiers MemPool{..} = MemPool
        (foldr' (uncurry HM.insert) mpProposals
             (HM.toList $ HM.map psProposal pmNewActiveProps))
        (foldr' insertVote mpLocalVotes .
             mapMaybe (\x -> (x,) <$> lookupVS pmNewActiveProps x) $ upVotes)
    addProposal Nothing  mp = mp
    addProposal (Just p) MemPool {..} = MemPool
        (HM.insert (hash p) p mpProposals)
        mpLocalVotes
    lookupVS activeProps UpdateVote{..} =
        HM.lookup uvProposalId activeProps >>= HM.lookup uvKey . psVotes
    insertVote e@(UpdateVote{..}, _) = HM.alter (append e) uvProposalId
    append e@(UpdateVote{..}, _) Nothing        = Just $ HM.singleton uvKey e
    append e@(UpdateVote{..}, _) (Just stVotes) = Just $ HM.insert uvKey e stVotes