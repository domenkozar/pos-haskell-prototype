{-# LANGUAGE AllowAmbiguousTypes #-}

module Pos.Ssc.Class.LocalStorage
       (
         SscLocalDataClass (..)
       ) where

import           Pos.Ssc.Class.Types (Ssc (..))
import           Universum

import           Pos.Types.Types     (SlotId)

class Ssc ssc => SscLocalDataClass ssc where
    sscNewLocalData :: MonadIO m => m (SscLocalData ssc)
    sscDestroyLocalData :: MonadIO m => SscLocalData ssc -> m ()
    -- first argument is global payload which is taken from main persistent storage
    sscProcessMessage :: MonadIO m => SscPayload ssc -> SscMessage ssc -> SscLocalData ssc -> m ()
    -- maybe should take global payload too
    sscGetLocalPayload :: MonadIO m => SlotId -> SscLocalData ssc -> m (SscPayload ssc)
