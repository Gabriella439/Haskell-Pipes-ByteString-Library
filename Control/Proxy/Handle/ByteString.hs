{-| This module provides utilities that fit with the idiom presented in
    @pipes-handle@, specifically for \"byte streams\", which are streams
    of strict 'BS.ByteString's chunks.
-}

module Control.Proxy.Handle.ByteString (
      drawBytes
    , passBytes
    ) where

import Control.Monad (when)
import qualified Control.Proxy as P
import Control.Proxy.Handle (draw, unDraw)
import Control.Proxy.Trans.State (StateP(StateP))
import qualified Data.ByteString as BS
import Data.Foldable (forM_)

--------------------------------------------------------------------------------
-- | @drawBytes n@ returns at-most @n@ bytes from upstream. If upstream cannot
-- produce @n@ bytes, then everything it could produce is returned.
drawBytes :: (Monad m, P.Proxy p)
    => Int
    -> StateP [Maybe BS.ByteString] p
        () (Maybe BS.ByteString)
        b' b
        m BS.ByteString
drawBytes = loop id
  where
    loop diffBs remainder
        | remainder <= 0 = return $ BS.concat (diffBs [])
        | otherwise = do
            mbs <- draw
            case mbs of
                Nothing -> return $ BS.concat (diffBs [])
                Just bs -> do
                    let len = BS.length bs
                    if len <= remainder
                        then loop (diffBs . (bs:)) (remainder - len)
                        else do
                            let (prefix, suffix) = BS.splitAt remainder bs
                            unDraw (Just suffix)
                            return $ BS.concat (diffBs [prefix])


--------------------------------------------------------------------------------
-- @skipBytes n@ skips @n@ bytes from upstream. If upstream does not respond
-- @n@ bytes, then all responded bytes are skipped and this computation returns.
passBytes :: (Monad m, P.Proxy p)
    => Int -> StateP [Maybe BS.ByteString] p () (Maybe BS.ByteString) b' b m ()
passBytes = loop
  where
    loop remainder = when (remainder > 0) $ do
        mbs <- draw
        forM_ mbs $ \bs -> do
            let len = BS.length bs
            if len <= remainder
                then loop (remainder - len)
                else do
                    let (_, suffix) = BS.splitAt remainder bs
                    unDraw (Just suffix)
                    return ()
