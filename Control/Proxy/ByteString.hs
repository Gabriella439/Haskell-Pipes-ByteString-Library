module Control.P.Proxy.ByteString where

import Control.Monad (forever)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer.Strict (WriterT, tell)
import qualified Control.Proxy as P
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Monoid (All(All), Any(Any), Sum(Sum))
import Data.Int (Int64)
import Data.Word (Word8)
import System.IO (Handle, hIsEOF)

defaultChunkSize :: Int
defaultChunkSize = 4096

packS :: (Monad m, P.Proxy p) => [Word8] -> () -> P.Producer p B.ByteString m ()
packS w8s () = P.runIdentityP $ P.respond (B.pack w8s)

unpackD
 :: (Monad m, P.Proxy p)
 => x -> p x B.ByteString x B.ByteString (WriterT [Word8] m) r
unpackD = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell $ B.unpack bs
    P.respond bs

fromStrictS
 :: (Monad m, P.Proxy p) => B.ByteString -> () -> P.Producer p B.ByteString m ()
fromStrictS bs () = P.runIdentityP $ P.respond bs

toStrictD
 :: (Monad m, P.Proxy p)
 => x -> p x B.ByteString x B.ByteString (WriterT B.ByteString m) r
toStrictD = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell bs
    P.respond bs

fromChunksS
 :: (Monad m, P.Proxy p) => [B.ByteString] -> () -> P.Producer p B.ByteString m ()
fromChunksS = P.fromListS

toChunksD
 :: (Monad m, P.Proxy p)
 => x -> p x B.ByteString x B.ByteString (WriterT [B.ByteString] m) r
toChunksD = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell [bs]
    P.respond bs

tailD :: (Monad m, P.Proxy p) => x -> p x B.ByteString x B.ByteString m r
tailD = P.runIdentityK go where
    go = \x -> do
        bs <- P.request x
        if (B.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else do
                x2 <- P.respond (BU.unsafeTail bs)
                P.idT x2

-- | Fold that returns whether 'All' received 'ByteString's are empty
nullD
 :: (Monad m, P.Proxy p)
 => x -> p x B.ByteString x B.ByteString (WriterT All m) r
nullD = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell $ All $ B.null bs
    P.respond bs

{-| Fold that returns whether 'All' received 'ByteString's are empty

    'nullD_' terminates on the first non-empty 'ByteString'. -}
nullD_
 :: (Monad m, P.Proxy p)
 => x -> p x B.ByteString x B.ByteString (WriterT All m) ()
nullD_ = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (B.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else lift $ tell $ All False

lengthD
 :: (Monad m, P.Proxy p)
 => x -> p x B.ByteString x B.ByteString (WriterT (Sum Int) m) r
lengthD = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell $ Sum $ B.length bs
    P.respond bs

mapD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Word8) -> x -> p x B.ByteString x B.ByteString m r
mapD f = P.mapD (B.map f)

intersperseD
 :: (Monad m, P.Proxy p) => Word8 -> () -> P.Pipe p B.ByteString B.ByteString m r
intersperseD w8 () = P.runIdentityP $ do
    bs0 <- P.request ()
    P.respond (B.intersperse w8 bs0)
    forever $ do
        P.respond (B.singleton w8)
        bs <- P.request ()
        P.respond (B.intersperse w8 bs)

intercalateD :: (Monad m, P.Proxy p)
 => B.ByteString -> () -> P.Pipe p B.ByteString B.ByteString m r
intercalateD bsi () = P.runIdentityP $ do
    bs0 <- P.request ()
    P.respond bs0
    forever $ do
        bs <- P.request ()
        P.respond bsi
        P.respond bs

concatMapD
 :: (Monad m, P.Proxy p)
 => (Word8 -> B.ByteString) -> x -> p x B.ByteString x B.ByteString m r
concatMapD f = P.mapD (B.concatMap f)

-- | Fold that returns whether 'Any' received 'Word8's satisfy the predicate
anyD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString (WriterT Any m) r
anyD pred = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell $ Any $ B.any pred bs
    P.respond bs

{-| Fold that returns whether 'Any' received 'Word8's satisfy the predicate

    'anyD_' terminates on the first 'Word8' that satisfies the predicate. -}
anyD_
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString (WriterT Any m) ()
anyD_ pred = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (B.any pred bs)
            then lift $ tell $ Any True
            else do
                x2 <- P.respond bs
                go x2

-- | Fold that returns whether 'All' received 'Word8's satisfy the predicate
allD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString (WriterT All m) r
allD pred = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell $ All $ B.all pred bs
    P.respond bs

{-| Fold that returns whether 'All' received 'Word8's satisfy the predicate

    'allD_' terminates on the first 'Word8' that fails the predicate. -}
allD_
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString (WriterT All m) ()
allD_ pred = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (B.all pred bs)
            then do
                x2 <- P.respond bs
                go x2
            else lift $ tell $ All False

{-
newtype Maximum a = Maximum { getMaximum :: Maybe a }

instance (Ord a) => Monoid (Maximum a) where
    mempty = Maximum Nothing
    mappend m1 (Maximum Nothing) = m1
    mappend (Maximum Nothing) m2 = m2
    mappend (Maximum (Just a1)) (Maximum (Just a2)) = Maximum (Just (max a1 a2))

maximumD
 :: (Monad m, P.Proxy p)
 => x -> p x B.ByteString x B.ByteString (WriterT (Maximum Word8) m) r
maximumD = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell $ Maximum $ Just $ B.maximum bs
    P.respond bs

newtype Minimum a = Minimum { getMinimum :: Maybe a }

instance (Ord a) => Monoid (Minimum a) where
    mempty = Minimum Nothing
    mappend m1 (Minimum Nothing) = m1
    mappend (Minimum Nothing) m2 = m2
    mappend (Minimum (Just a1)) (Minimum (Just a2)) = Minimum (Just (min a1 a2))

minimumD
 :: (Monad m, P.Proxy p)
 => x -> p x B.ByteString x B.ByteString (WriterT (Minimum Word8) m) r
minimumD = P.runIdentityK $ P.foreverK $ \x -> do
    bs <- P.request x
    lift $ tell $ Minimum $ Just $ B.minimum bs
    P.respond bs
-}

takeD :: (Monad m, P.Proxy p) => Int -> x -> p x B.ByteString x B.ByteString m x
takeD n0 = P.runIdentityK (go n0) where
    go n
        | n <= 0 = return
        | otherwise = \x -> do
            bs <- P.request x
            let len = B.length bs
            if (len > n)
                then P.respond (BU.unsafeTake n bs)
                else do
                    x2 <- P.respond bs
                    go (n - len) x2

takeD_
 :: (Monad m, P.Proxy p) => Int -> x -> p x B.ByteString x B.ByteString m ()
takeD_ n0 = P.runIdentityK (go n0) where
    go n
        | n <= 0 = \_ -> return ()
        | otherwise = \x -> do
            bs <- P.request x
            let len = B.length bs
            if (len > n)
                then do
                    P.respond (BU.unsafeTake n bs)
                    return ()
                else do
                    x2 <- P.respond bs
                    go (n - len) x2

dropD
 :: (Monad m, P.Proxy p) => Int -> () -> P.Pipe p B.ByteString B.ByteString m r
dropD n0 () = P.runIdentityP (go n0) where
    go n
        | n <= 0 = P.idT ()
        | otherwise = do
            bs <- P.request ()
            let len = B.length bs
            if (len >= n)
                then do
                    P.respond (BU.unsafeDrop n bs)
                    P.idT ()
                else go (n - len)

takeWhileD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString m ()
takeWhileD pred = P.runIdentityK go where
    go x = do
        bs <- P.request x
        case B.findIndex (not . pred) bs of
            Nothing -> do
                x2 <- P.respond bs
                go x2
            Just i -> do
                P.respond (BU.unsafeTake i bs)
                return ()

dropWhileD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> () -> P.Pipe p B.ByteString B.ByteString m r
dropWhileD pred () = P.runIdentityP go where
    go = do
        bs <- P.request ()
        case B.findIndex (not . pred) bs of
            Nothing -> go
            Just i -> do
                P.respond (BU.unsafeDrop i bs)
                P.idT ()

groupD
 :: (Monad m, P.Proxy p) => () -> P.Pipe p (Maybe B.ByteString) B.ByteString m ()
groupD = groupByD (==)

groupByD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Word8 -> Bool)
 -> () -> P.Pipe p (Maybe B.ByteString) B.ByteString m ()
groupByD eq () = P.runIdentityP go1 where
    go1 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> return ()
            Just bs
                | B.null bs -> go1
                | otherwise -> do
                    let groups = B.groupBy eq bs
                    mapM_ P.respond (init groups)
                    go2 (last groups)
    go2 group0 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> P.respond group0
            Just bs
                | B.null bs -> go2 group0
                | otherwise -> do
                    let groups = B.groupBy eq bs
                    case groups of
                        []              -> go2 group0
                        [group1]        -> go2 (B.append group0 group1)
                        gs@(group1:gs') -> do
                            if (B.head group0 == B.head group1)
                                then do
                                    P.respond (B.append group0 group1)
                                    mapM_ P.respond (init gs')
                                    go2 (last gs')
                                else do
                                    P.respond group0
                                    mapM_ P.respond (init gs )
                                    go2 (last gs )

splitWithD
 :: (Monad m, P.Proxy p)
 => (Word8 -> Bool) -> () -> P.Pipe p (Maybe B.ByteString) B.ByteString m ()
splitWithD pred () = P.runIdentityP go1 where
    go1 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> return ()
            Just bs -> case B.splitWith pred bs of
                [] -> go1
                gs -> do
                    mapM_ P.respond (init gs)
                    go2 (last gs)
    go2 group0 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> P.respond group0
            Just bs -> case B.splitWith pred bs of
                []        -> go2 group0
                [group1]  -> go2 (B.append group0 group1)
                group1:gs -> do
                    P.respond (B.append group0 group1)
                    mapM_ P.respond (init gs)
                    go2 (last gs)

hGetS :: (P.Proxy p) => Int -> Handle -> () -> P.Producer p B.ByteString IO ()
hGetS size h () = P.runIdentityP go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ B.hGet h size
                P.respond bs
                go

hReadFileS :: (P.Proxy p) => Handle -> () -> P.Producer p B.ByteString IO ()
hReadFileS = hGetS defaultChunkSize

hGetLineS :: (P.Proxy p) => Handle -> () -> P.Producer p B.ByteString IO ()
hGetLineS h () = P.runIdentityP go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ B.hGetLine h
                P.respond bs
                go
