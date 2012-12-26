module Control.P.Proxy.ByteString where

import Control.Monad (forever)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT)
import Control.Monad.Trans.Writer.Strict (WriterT, tell)
import qualified Control.Proxy as P
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Lazy.Internal as BLI
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Monoid as M
import Data.Int (Int64)
import Data.Word (Word8)
import System.IO (Handle, hIsEOF)

defaultChunkSize :: Int
defaultChunkSize = 4096

fromLazyS
 :: (Monad m, P.Proxy p)
 => BL.ByteString -> () -> P.Producer p BS.ByteString m ()
fromLazyS bs () =
    P.runIdentityP $ BLI.foldrChunks (\e a -> P.respond e >> a) (return ()) bs

toLazyD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (M.Endo BL.ByteString) m) r
toLazyD = P.foldrD BLI.Chunk

headD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (M.First Word8) m) r
headD = P.foldD (\bs ->
    if (BS.null bs)
        then M.First Nothing
        else M.First $ Just $ BU.unsafeHead bs )

headD_
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (M.First Word8) m) ()
headD_ = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else lift $ tell $ M.First $ Just $ BU.unsafeHead bs
lastD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (M.Last Word8) m) r
lastD = P.foldD (\bs ->
    if (BS.null bs)
        then M.Last Nothing
        else M.Last $ Just $ BS.last bs )

tailD :: (Monad m, P.Proxy p) => x -> p x BS.ByteString x BS.ByteString m r
tailD = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else do
                x2 <- P.respond (BU.unsafeTail bs)
                P.idT x2

-- | Fold that returns whether 'M.All' received 'ByteString's are empty
nullD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT M.All m) r
nullD = P.foldD (M.All . BS.null)

{-| Fold that returns whether 'M.All' received 'ByteString's are empty

    'nullD_' terminates on the first non-empty 'ByteString'. -}
nullD_
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT M.All m) ()
nullD_ = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else lift $ tell $ M.All False

lengthD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (M.Sum Int) m) r
lengthD = P.foldD (M.Sum . BS.length)

mapD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Word8) -> x -> p x BS.ByteString x BS.ByteString m r
mapD f = P.mapD (BS.map f)

intersperseD
 :: (Monad m, P.Proxy p) => Word8 -> () -> P.Pipe p BS.ByteString BS.ByteString m r
intersperseD w8 () = P.runIdentityP $ do
    bs0 <- P.request ()
    P.respond (BS.intersperse w8 bs0)
    forever $ do
        P.respond (BS.singleton w8)
        bs <- P.request ()
        P.respond (BS.intersperse w8 bs)

intercalateD
 :: (Monad m, P.Proxy p)
 => BS.ByteString -> () -> P.Pipe p BS.ByteString BS.ByteString m r
intercalateD bsi () = P.runIdentityP $ do
    bs0 <- P.request ()
    P.respond bs0
    forever $ do
        bs <- P.request ()
        P.respond bsi
        P.respond bs

foldlD'
 :: (Monad m, P.Proxy p)
 => (a -> Word8 -> a) -> x -> p x BS.ByteString x BS.ByteString (StateT a m) r
foldlD' f = P.foldlD' (BS.foldl' f)

foldrD
 :: (Monad m, P.Proxy p)
 => (Word8 -> a -> a)
 -> x -> p x BS.ByteString x BS.ByteString (WriterT (M.Endo a) m) r
foldrD f = P.foldrD (\e a -> BS.foldr f a e)

concatMapD
 :: (Monad m, P.Proxy p)
 => (Word8 -> BS.ByteString) -> x -> p x BS.ByteString x BS.ByteString m r
concatMapD f = P.mapD (BS.concatMap f)

-- | Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate
anyD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool)
 -> x -> p x BS.ByteString x BS.ByteString (WriterT M.Any m) r
anyD pred = P.foldD (M.Any . BS.any pred)

{-| Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate

    'anyD_' terminates on the first 'Word8' that satisfies the predicate. -}
anyD_
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool)
 -> x -> p x BS.ByteString x BS.ByteString (WriterT M.Any m) ()
anyD_ pred = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (BS.any pred bs)
            then lift $ tell $ M.Any True
            else do
                x2 <- P.respond bs
                go x2

-- | Fold that returns whether 'M.All' received 'Word8's satisfy the predicate
allD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool)
 -> x -> p x BS.ByteString x BS.ByteString (WriterT M.All m) r
allD pred = P.foldD (M.All . BS.all pred)

{-| Fold that returns whether 'M.All' received 'Word8's satisfy the predicate

    'allD_' terminates on the first 'Word8' that fails the predicate. -}
allD_
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool)
 -> x -> p x BS.ByteString x BS.ByteString (WriterT M.All m) ()
allD_ pred = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (BS.all pred bs)
            then do
                x2 <- P.respond bs
                go x2
            else lift $ tell $ M.All False

{-
newtype Maximum a = Maximum { getMaximum :: Maybe a }

instance (Ord a) => Monoid (Maximum a) where
    mempty = Maximum Nothing
    mappend m1 (Maximum Nothing) = m1
    mappend (Maximum Nothing) m2 = m2
    mappend (Maximum (Just a1)) (Maximum (Just a2)) = Maximum (Just (max a1 a2))

maximumD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (Maximum Word8) m) r
maximumD = P.foldD (\bs ->
    if (BS.null bs)
        then Maximum Nothing
        else Maximum $ Just $ BS.maximum bs )

newtype Minimum a = Minimum { getMinimum :: Maybe a }

instance (Ord a) => Monoid (Minimum a) where
    mempty = Minimum Nothing
    mappend m1 (Minimum Nothing) = m1
    mappend (Minimum Nothing) m2 = m2
    mappend (Minimum (Just a1)) (Minimum (Just a2)) = Minimum (Just (min a1 a2))

minimumD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (Minimum Word8) m) r
minimumD = P.foldD (\bs ->
    if (BS.null bs)
        then Minimum Nothing
        else Minimum $ Just $ BS.minimum bs )
-}

takeD :: (Monad m, P.Proxy p) => Int -> x -> p x BS.ByteString x BS.ByteString m x
takeD n0 = P.runIdentityK (go n0) where
    go n
        | n <= 0 = return
        | otherwise = \x -> do
            bs <- P.request x
            let len = BS.length bs
            if (len > n)
                then P.respond (BU.unsafeTake n bs)
                else do
                    x2 <- P.respond bs
                    go (n - len) x2

takeD_
 :: (Monad m, P.Proxy p) => Int -> x -> p x BS.ByteString x BS.ByteString m ()
takeD_ n0 = P.runIdentityK (go n0) where
    go n
        | n <= 0 = \_ -> return ()
        | otherwise = \x -> do
            bs <- P.request x
            let len = BS.length bs
            if (len > n)
                then do
                    P.respond (BU.unsafeTake n bs)
                    return ()
                else do
                    x2 <- P.respond bs
                    go (n - len) x2

dropD
 :: (Monad m, P.Proxy p) => Int -> () -> P.Pipe p BS.ByteString BS.ByteString m r
dropD n0 () = P.runIdentityP (go n0) where
    go n
        | n <= 0 = P.idT ()
        | otherwise = do
            bs <- P.request ()
            let len = BS.length bs
            if (len >= n)
                then do
                    P.respond (BU.unsafeDrop n bs)
                    P.idT ()
                else go (n - len)

takeWhileD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> x -> p x BS.ByteString x BS.ByteString m ()
takeWhileD pred = P.runIdentityK go where
    go x = do
        bs <- P.request x
        case BS.findIndex (not . pred) bs of
            Nothing -> do
                x2 <- P.respond bs
                go x2
            Just i -> do
                P.respond (BU.unsafeTake i bs)
                return ()

dropWhileD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> () -> P.Pipe p BS.ByteString BS.ByteString m r
dropWhileD pred () = P.runIdentityP go where
    go = do
        bs <- P.request ()
        case BS.findIndex (not . pred) bs of
            Nothing -> go
            Just i -> do
                P.respond (BU.unsafeDrop i bs)
                P.idT ()

groupD
 :: (Monad m, P.Proxy p)
 => () -> P.Pipe p (Maybe BS.ByteString) BS.ByteString m r
groupD = groupByD (==)

groupByD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Word8 -> Bool)
 -> () -> P.Pipe p (Maybe BS.ByteString) BS.ByteString m r
groupByD eq () = P.runIdentityP go1 where
    go1 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> go1
            Just bs
                | BS.null bs -> go1
                | otherwise -> do
                    let groups = BS.groupBy eq bs
                    mapM_ P.respond (init groups)
                    go2 (last groups)
    go2 group0 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> do
                P.respond group0
                go1
            Just bs
                | BS.null bs -> go2 group0
                | otherwise -> do
                    let groups = BS.groupBy eq bs
                    case groups of
                        []              -> go2 group0
                        [group1]        -> go2 (BS.append group0 group1)
                        gs@(group1:gs') -> do
                            if (BS.head group0 == BS.head group1)
                                then do
                                    P.respond (BS.append group0 group1)
                                    mapM_ P.respond (init gs')
                                    go2 (last gs')
                                else do
                                    P.respond group0
                                    mapM_ P.respond (init gs )
                                    go2 (last gs )

splitD
 :: (Monad m, P.Proxy p)
 => Word8 -> () -> P.Pipe p (Maybe BS.ByteString) BS.ByteString m r
splitD w8 = splitWithD (w8 ==)

splitWithD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> () -> P.Pipe p (Maybe BS.ByteString) BS.ByteString m r
splitWithD pred () = P.runIdentityP go1 where
    go1 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> go1
            Just bs -> case BS.splitWith pred bs of
                [] -> go1
                gs -> do
                    mapM_ P.respond (init gs)
                    go2 (last gs)
    go2 group0 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> do
                P.respond group0
                go1
            Just bs -> case BS.splitWith pred bs of
                []        -> go2 group0
                [group1]  -> go2 (BS.append group0 group1)
                group1:gs -> do
                    P.respond (BS.append group0 group1)
                    mapM_ P.respond (init gs)
                    go2 (last gs)

elemD
 :: (Monad m, P.Proxy p)
 => Word8 -> x -> p x BS.ByteString x BS.ByteString (WriterT M.Any m) r
elemD w8 = P.foldD (M.Any . BS.elem w8)

elemD_
 :: (Monad m, P.Proxy p)
 => Word8 -> x -> p x BS.ByteString x BS.ByteString (WriterT M.Any m) ()
elemD_ w8 = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (BS.elem w8 bs)
            then lift $ tell $ M.Any True
            else do
                x2 <- P.respond bs
                go x2

notElemD
 :: (Monad m, P.Proxy p)
 => Word8 -> x -> p x BS.ByteString x BS.ByteString (WriterT M.All m) r
notElemD w8 = P.foldD (M.All . BS.notElem w8)

hGetS :: (P.Proxy p) => Int -> Handle -> () -> P.Producer p BS.ByteString IO ()
hGetS size h () = P.runIdentityP go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGet h size
                P.respond bs
                go

hReadFileS :: (P.Proxy p) => Handle -> () -> P.Producer p BS.ByteString IO ()
hReadFileS = hGetS defaultChunkSize

hGetLineS :: (P.Proxy p) => Handle -> () -> P.Producer p BS.ByteString IO ()
hGetLineS h () = P.runIdentityP go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGetLine h
                P.respond bs
                go
