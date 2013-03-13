{-# LANGUAGE MonadComprehensions, TupleSections, ImplicitParams, FlexibleContexts, TemplateHaskell #-}
import Control.Applicative
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Free
import Data.List
import Data.Function
import Data.Array
import Data.Char
import Data.Maybe
import Data.Vect
import qualified Data.Map as M
import System.Directory
import Graphics.FreeGame
import Paths_Monaris

loadBitmapsWith 'getDataFileName "images"

picBlocks :: M.Map (Int, Int) Picture
picBlocks = M.fromAscList [((i, j), Bitmap $ cropBitmap _blocks_png (48, 48) (i * 48, j * 48))
    | i <- [0..6], j <- [0..7]]

picChars :: M.Map Char Picture
picChars = M.fromAscList [(intToDigit n, Bitmap $ cropBitmap _numbers_png (24, 32) (n * 24, 0))
    | n <- [0..9]]

blockSize, picCharWidth :: Float
blockSize = 24
picCharWidth = 24

type Field = Array Coord (Maybe BlockColor)
type BlockColor = Int
type Coord = (Int, Int)
type Polyomino = [Coord]

pair f (x, y) = (f x, f y)
pair2 f (a, b) (c, d) = (f a c, f b d)

polyominos :: [([(Int, Int)], BlockColor)]
polyominos = [([(0,0),(0,1),(0,2),(0,3)], 3)
             ,([(0,0),(0,1),(1,0),(1,1)], 1)
             ,([(0,0),(0,1),(0,2),(1,2)], 6)
             ,([(0,0),(0,1),(0,2),(-1,2)], 4)
             ,([(0,0),(0,1),(1,1),(1,2)], 2)
             ,([(0,0),(0,1),(-1,1),(-1,2)], 0)
             ,([(0,0),(-1,0),(1,0),(0,1)], 5)]

translate :: Coord -> Polyomino -> Polyomino
translate = map . pair2 (+)

spin :: (Coord -> Coord) -> Coord -> Polyomino -> Polyomino
spin t center = map $ pair (`div`2) . pair2 (+) center . t . pair2 subtract center . pair (2*) where 

centers :: Polyomino -> [Coord]
centers cs = cs' ++ [i | i@(c, r) <- map (pair2 (+) (1,1)) cs'
    , let c0 = minimum (map fst cs'), let c1 = maximum (map fst cs')
    , let r0 = minimum (map snd cs'), let r1 = maximum (map snd cs')
    , c0 < c && c < c1, r0 < r && r < r1] where cs' = map (pair (2*)) cs

completeLines :: Field -> [Int]
completeLines field = [r | r <- [r0..r1], all isJust [field ! (c, r) | c <- [c0..c1]]] where
    ((c0, r0), (c1, r1)) = bounds field

deleteLine :: Field -> Int -> Field
deleteLine field n = array bnd [ a' | a@(ix@(c, r), _) <- assocs field
    , let a' | r == r0 = (ix, Nothing)
             | r <= n = (ix, field ! (c, r - 1))
             | otherwise = a] where
         bnd@((_, r0), _) = bounds field

putToField :: BlockColor -> Field -> Polyomino -> Maybe Field
putToField color field omino = [field // map (,Just color) omino
    | all ((&&) <$> inRange (bounds field) <*> fmap isNothing (field !)) omino]

getPolyomino :: Game (Polyomino, BlockColor)
getPolyomino = (polyominos!!) <$> randomness (0, length polyominos - 1)

spinStrategy :: Polyomino -> Field -> [Polyomino] -> Polyomino
spinStrategy original field = maximumBy (compare `on` ev) where
    g xs = fromIntegral (sum (map snd xs)) / fromIntegral (length xs)
    ev x = sum [fromEnum (g original <= g x)
               + sum [1 | c <- neighbors, not (inRange (bounds field) c) || isJust (field ! c)] ^ 2
            | r <- nub $ map snd x]
        where neighbors = nub $ pair2 (+) <$> x <*> [(0, 1), (0, -1), (1, 0), (1, 1)]

place :: Polyomino -> BlockColor -> Field -> Int -> Game (Maybe Field)
place polyomino color field period = do
    if or [isJust $ field ! (c, r) | (c, r) <- range ((c0, r0), (c1, -1))] then return Nothing 
        else run 1 (Left 0) (False, False, False, False, False, False)
            `evalStateT` translate (5, -1 - maximum (map snd polyomino)) polyomino
    where
    ((c0, r0), (c1, r1)) = bounds field
    putF = putToField color field
    run t param ks = do
        [l',r',u',d',z',x'] <- lift $ mapM getButtonState [KeyLeft, KeyRight, KeyUp, KeyDown, KeyChar 'Z', KeyChar 'X']
        when (t `mod` period == 0) $ void $ move (0, 1)

        omino <- get
        
        param' <- flip runReaderT (ks, (l',r',u',d',z',x'))
            $ if isNothing $ putF $ translate (0, 1) omino
                then fmap Right <$> handleLanding (either (const (60, 120)) id param)
                else fmap Left <$> handleNotLanding (either id (const 0) param)
        drawPicture $ renderField field
        drawPicture $ renderPolyomino 0 omino color        
        case param' of
            Just p -> tick >> run (succ t) p (l',r',u',d',z',x')
            Nothing -> return (putF omino)
    
    handleCommon = do
        ((l,r,_,_,z,x),(l',r',_,_,z',x')) <- ask
        a <- case (not l && l', not r && r') of
            (True, False) -> move (-1, 0)
            (False, True) -> move (1, 0)
            _ -> return False
        b <- case (not z && z', not x && x') of
            (True, False) -> sp (\(s, t) -> (-t, s))
            (False, True) -> sp (\(s, t) -> (t, -s))
            _ -> return False
        return $ a || b
    
    handleLanding (0, _) = return Nothing
    handleLanding (play, playBound) = do
        ((_,_,u,d,_,_),(_,_,u',d',_,_)) <- ask
        omino <- get
        drawPicture $ renderPolyomino 7 omino color
        if not u && u' || not d && d' then return Nothing else do
            f <- handleCommon
            return $ Just $ if f then (playBound / 2, playBound - 10) else (play - 1, playBound)
    
    handleNotLanding t = do
        _ <- handleCommon
        ((_,_,u,_,_,_),(_,_,u',d',_,_)) <- ask
        omino <- get
        drawPicture $ renderPolyomino 6 (destination omino) color
        when (not u && u') $ modify destination
        if d'
            then do
                when (t `mod` 5 == 0) $ void $ move (0, 1)
                return (Just (succ t))
            else return (Just 0)

    move dir = do omino <- translate dir <$> get
                  if isJust $ putF omino
                      then put omino >> return True
                      else return False
    
    sp dir = do omino <- get
                case filter (isJust . putF) $ map (flip (spin dir) omino) $ centers omino of
                     [] -> return False
                     xs -> put (spinStrategy omino field xs) >> return True

    destination omino
        | isNothing $ putF omino' = omino
        | otherwise = destination omino'
        where omino' = translate (0, 1) omino

eliminate :: Field -> Game (Field, Int)
eliminate field = do
    unless (null rows) $ forM_ [0..5] $ \i -> replicateM_ 2 $ draw i >> tick
    return (foldl deleteLine field rows, length rows)
    where
        rows = completeLines field
        draw n = drawPicture $ flip renderFieldBy field
            $ \(_, r) color -> picBlocks M.! (color, if r `elem` rows then n else 0)

gameMain :: (?highScore :: Int) => Field -> Int -> Float -> (Polyomino, BlockColor) -> (Polyomino, BlockColor) -> Game Int
gameMain field total line (omino, color) next = do
    r <- embed $ place omino color field (floor $ 60 * 2**(-line/40))
    case r of
        Nothing -> total <$ embed (gameOver field)
        Just field' -> do
            (field'', n) <- embed $ eliminate field'
            next' <- getPolyomino
            gameMain field'' (total + n ^ 2) (line + fromIntegral n) next next'
    where
        embed (Pure a) = return a
        embed m = do
            let drawTo x y = drawPicture . Translate (Vec2 x y)
            drawTo 320 240 $ Bitmap _background_png
            cont <- hoistFree (transPicture $ Translate (Vec2 24 24)) $ do
                drawPicture $ renderFieldBackground field
                untick m
            drawTo 480 133 $ renderString $ show total
            drawTo 480 166 $ renderString $ show ?highScore
            drawTo 500 220 $ uncurry (renderPolyomino 0) next
            tick
            embed $ either id Pure cont

gameTitle :: (?highScore :: Int) => Game ()
gameTitle = do
    z <- getButtonState (KeyChar 'Z')
    drawPicture $ Translate (Vec2 320 240) (Bitmap _title_png)
    drawPicture $ Translate (Vec2 490 182) $ renderString $ show ?highScore
    tick
    unless z gameTitle

blockPos :: Int -> Int -> Vec2
blockPos c r = blockSize *& Vec2 (fromIntegral c) (fromIntegral r)

gameOver :: Field -> Game ()
gameOver field = do
    let pics = [Translate (blockPos c r) (picBlocks M.! (p, 0))
            | ((c, r), color) <- assocs field, p <- maybeToList color]
    objs <- forM pics $ \pic -> do
        dx <- randomness (-1,1)
        return (zero, Vec2 dx (-3), pic)
    void $ foldM run objs [1..120]
    where
        update (pos, v, pic) = (pos &+ v, v &+ Vec2 0 0.2, pic) <$ drawPicture (Translate pos pic)
        run objs = const $ mapM update objs <* tick

renderFieldBackground :: Field -> Picture
renderFieldBackground field = Pictures [blockPos c r `Translate` Bitmap _block_background_png | (c, r) <- indices field, r >= 0]

renderField :: Field -> Picture
renderField = renderFieldBy $ \_ color -> picBlocks M.! (color, 0)

renderFieldBy :: (Coord -> BlockColor -> Picture) -> Field -> Picture
renderFieldBy f field = Pictures [blockPos c r `Translate` pic
    | (ix@(c, r), color) <- assocs field, r >= 0, pic <- maybeToList $ f ix <$> color]

renderPolyomino :: Int -> Polyomino -> BlockColor -> Picture
renderPolyomino i omino color = Pictures [blockPos c r `Translate` picBlocks M.! (color, i)
    | (c, r) <- omino, r >= 0]

renderString :: String -> Picture
renderString str = Pictures [Vec2 (picCharWidth * i) 0 `Translate` picChars M.! ch | (i, ch) <- zip [0..] str]

main :: IO ()
main = void $ runGame (defaultGameParam {windowTitle="Monaris"}) $ do
    let initialField = listArray ((0,-4), (9,18)) (repeat Nothing)
    highscorePath <- embedIO $ (++"/.monaris_highscore") <$> getHomeDirectory
    let loop h = do
            let ?highScore = h
            gameTitle
            score <- join $ gameMain initialField 0 0 <$> getPolyomino <*> getPolyomino
            when (?highScore < score) $ embedIO $ writeFile highscorePath (show score)
            
            loop (max score h)
    f <- embedIO $ doesFileExist highscorePath
    (if f then embedIO $ read <$> readFile highscorePath else return 0) >>= loop
