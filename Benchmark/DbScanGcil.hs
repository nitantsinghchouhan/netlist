
import Control.Monad
import Control.Monad.State
import Data.Map as M
import System.Random

import Circuit.NetList
import Circuit.NetList.Gcil
import qualified Circuit.Stack
import Test.Util.Simple
import Util

-- This version of DBSCAN does not return core vs non-core point records
-- Return value assigns each input data point to a cluster index, starting with
-- 1. Cluster index 0 means outlier. Also returns the total cluster count

dbscan :: (a -> a -> Bool) -> Int -> [a] -> ([Int],Int)
dbscan neighbor minpts l = aux (zip [0..] l) M.empty 0 where
  aux [] clus cc = (M.elems clus,cc)
  aux ((i,x):ps) clus cc 
    | M.member i clus = aux ps clus cc
    | nc < minpts     = aux ps (M.insert i 0 clus) cc
    | otherwise       = cc' `seq` aux ps clus' cc'
    where
    nc = length ne
    ne = [j | (j,x') <- zip [0..] l, neighbor x x']
    cc' = cc+1
    clus' = dbscanExpand neighbor minpts clus cc' l ne

-- Assumes initKey is not an outlier
dbscanExpand neighbor minpts clusInit cc l initKeys = aux clusInit initKeys
  where
  asc = zip [0..] l
  aux clus [] = clus
  aux clus (i:is)
    | M.member i clus && clus M.! i /= 0 = aux clus  is
    | nc < minpts     = aux clus' is
    | otherwise       = aux clus' $ ne++is
    where
    clus' = M.insert i cc clus
    ne = [j | (j,x) <- asc, neighbor x curx]
    nc = length ne
    curx = l!!i

-- The same depth-first algorithm presented above is now a circuit below
-- For more info, look at circitizeDbscan.txt

-- 'emptystk' here is just a hack into the type system, so that I can
--   specify the internal stack type being used when calling the function
dbscanGcil :: (StackType s,Swappable a) 
           => s NetUInt -> (a -> a -> NetWriter NetBool) -> Int -> [a]
           -> NetWriter ([NetUInt],NetUInt)
dbscanGcil emptystk neighbor minpts l = do
  let cc = constInt 0
      outerLoop = netTrue
      i = constIntW (valueSize n) 0
      cluster = replicate n (constInt 0)

  (cluster,cc,_,_,_) <- foldM (\(cluster,cc,outerLoop,i,stk) _ -> do
    inloop <- greaterThan (constInt n) i
    startExpand <- do c2 <- equal (constInt 0) =<< muxList i cluster
                      netAnds [outerLoop,inloop,c2]
    let checkNeighbor = startExpand
        cp = i
    mbtop <- stkTop stk
    innerLoop  <- netNot outerLoop
    outerLoop' <- netAnd outerLoop =<< netNot startExpand
    (cluster,outerLoop',stk,checkNeighbor,cp,i) <- condModMaybe 
      (\en (clus,ol',stk,cnegh,cp,i) -> do 
        ol' <- netOr ol' en
        return (clus,ol',stk,cnegh,cp,i))
      (\curi en (clus,ol',stk,cnegh,cp,i) -> do
        stk  <- stkCondPop en stk
        en   <- netAnd en =<< equal (constInt 0) =<< muxList curi clus
        clus <- naiveListWrite en curi cc clus
        cp   <- mux en cp curi
        cnegh<- netOr cnegh en
        return (clus,ol',stk,cnegh,cp,i))
      mbtop innerLoop (cluster,outerLoop',stk,checkNeighbor,cp,i)

    cur <- muxList cp l
    closeVec <- mapM (neighbor cur) l
    nc  <- countTrue closeVec
    pc  <- netAnd checkNeighbor =<< greaterThan nc (constInt $ minpts-1)
    stk <- foldM (\stk (x,c) -> do 
      c' <- netAnd c pc
      stkCondPush c' (constInt x) stk) stk $ zip [0..] closeVec
    cc <- do c <- netAnds [outerLoop, inloop, pc] -- old outerLoop, no "'"
             condAdd c cc (constInt 1)

    outerEnd <- netAnd outerLoop' inloop
    i <- condAdd outerEnd i (constInt 1)

    return (cluster,cc,outerLoop',i,stk)
    ) (cluster,cc,outerLoop,i,stkCapLength (n*n) emptystk) [1..2*n]
  return (cluster,cc)

  where n = length l

-- Feels like I am learning programming for the first time:
--   rampant code and bug duplication. TODO cleanup
dbscanGcilSimple :: (StackType s, Swappable a) 
           => s NetUInt -> (a -> a -> NetWriter NetBool) -> Int -> [a]
           -> NetWriter ([NetUInt],NetUInt)
-- 'emptystk' here is just a hack into the type system, so that I can
--   specify the internal stack type being used when calling the function
dbscanGcilSimple emptystk neighbor minpts l = do
  let cc      = constIntW (valueSize n) 0 -- actually, ceil valueSize/minpts TODO
      cluster = replicate n (constIntW (valueSize n) 0)
      stk     = stkCapLength n emptystk
      i       = constIntW (valueSize n) 0
      outer   = netTrue
      pushed  = replicate n netFalse
  (pushed,outer,cc,stk,cluster,i) 
    <- foldM (\(pushed,outer,cc,stk,cluster,i) _ -> do
    inloop <- greaterThan (constInt n) i
    startExpand <- do c <- equal (constInt 0) =<< muxList i cluster
                      netAnds [outer,c,inloop]
    let pushNeigh = startExpand
        cp = i; oldOuter = outer
    inner  <- netNot outer
    outer' <- netAnd outer =<< netNot startExpand
    mbtop  <- stkTop stk
    (pushed,outer',stk,cluster,cp,pushNeigh) <- condModMaybe
      (\en (pushed,outer',stk,clus,cp,pushn) -> do
        outer' <- netOr outer' en
        return (pushed,outer',stk,clus,cp,pushn))
      (\curi en (pushed,outer',stk,clus,cp,pushn) -> do
        stk   <- stkCondPop en stk
        en    <- netAnd en =<< equal (constInt 0) =<< muxList curi clus
        clus  <- naiveListWrite en curi cc clus
        cp    <- mux en cp curi
        pushn <- netOr pushn en
        return (pushed,outer',stk,clus,cp,pushn))
      mbtop inner (pushed,outer',stk,cluster,cp,pushNeigh)
    cur <- muxList cp l
    closeVec <- mapM (neighbor cur) l
    nc <- countTrue closeVec
    pc <- netAnd pushNeigh =<< greaterThan nc (constInt $ minpts-1)
    (stk,rpushed) <- foldM (\(stk,rpushed) (x,c,mepushed) -> do
      c'  <- netAnd pc c
      c'' <- netAnd c' =<< netNot mepushed
      mepushed <- netXor mepushed c'' -- netOr c' mepushed
      stk <- stkCondPush c'' (constInt x) stk
      return (stk,mepushed:rpushed)) (stk,[]) $ zip3 [0..] closeVec pushed
    notpc <- netNot pc
    outer' <- netOr outer' =<< netAnds [inloop,notpc,pushNeigh,oldOuter]
    let pushed = reverse rpushed
    cc <- do c <- netAnds [pc,oldOuter,inloop]
             condAdd c cc (constInt 1)
    i  <- do c <- netAnd outer' inloop
             condAdd c i (constInt 1)
    return (pushed,outer',cc,stk,cluster,i)
    ) (pushed,outer,cc,stk,cluster,i) [1..2*n]
  return (cluster,cc)
  where n = length l


-- TODO eyeball this a little longer with circitize by the side
-- Make a new data maker. Fix data range. Run, debug, collect data.

netDiff a b = do c <- greaterThan a b
                 bind2 (mux c) (sub b a) (sub a b)

dist p1 p2 = do bind2 add (netDiff (fst p1) (fst p2)) 
                          (netDiff (snd p1) (snd p2))

-- Counts in a convoluted way to reduce bitwidths as much as possible
countTrue :: [NetBool] -> NetWriter NetUInt
countTrue [] = return (constIntW 1 0)
countTrue l 
  | Just (h,t) <- oddLength = do zo <- liftM intFromBits $ bitify h
                                 add zo =<< countTrue t
  | otherwise = do r1 <- countTrue t1
                   r2 <- countTrue t2
                   add r1 =<< extendBy 1 r2
  where
  n = length l
  half = n `div` 2
  (t1,t2) = splitAt half l
  oddLength | odd (length l) = Just (head l, tail l)
            | otherwise = Nothing


makeBoxCluster (lox,hix) (loy,hiy) n rgen 
  = flip runState rgen $ replicateM n $ do x <- state $ randomR (lox,hix)
                                           y <- state $ randomR (loy,hiy)
                                           return (x,y)

testData clusterDim pointsInCluster clusterCount rgen 
  = flip runState rgen $ liftM concat $ replicateM clusterCount randomPlace
  where
  randomPlace = do x0 <- state $ randomR (0,10000)
                   y0 <- state $ randomR (0,10000)
                   state $ makeBoxCluster (x0, x0+clusterDim) 
                                          (y0, y0+clusterDim)
                                          pointsInCluster

testParams :: Int -> Int -> (Int,Int)
testParams clusterDim pointsInCluster = (eps, expected) where
  target = 9
  density = fromIntegral pointsInCluster 
          / fromIntegral (clusterDim*clusterDim) :: Double
  eps = floor $ sqrt $ fromIntegral target/(2*density)
  expected = target `div` 2 + 1

testNeighbor eps p1 p2 = do d <- dist p1 p2
                            netNot =<< greaterThan d (constInt eps)

packAndTest name serverInput clientInput driver = burnBenchmark name $ do
  l1 <- mapM (testPair ServerSide) serverInput
  l2 <- mapM (testPair ClientSide) clientInput
  (clus,cc) <- liftNet $ driver $ l1++l2
  gcilOutBits cc
  gcilOutBits =<< liftNet (countTrue =<< mapM (equal (constInt 1)) clus)
  where
  w=16
  testPair side (x,y) = do xv <- testInt side w x
                           yv <- testInt side w y
                           return (xv::NetUInt,yv::NetUInt)

type Points = (NetUInt,NetUInt)

{-
main = do let cdim = 2; cc = 3; pic = 10
          l1 <- getStdRandom (testData cdim pic cc)
          l2 <- getStdRandom (testData cdim pic cc)
          let (eps,minpts) = testParams cdim pic
              neigh p q = abs (fst p - fst q) + abs (snd p - snd q) <= eps
          putStrLn $ show $ minpts
          putStrLn $ show $ dbscan neigh minpts (l1++l2)
-}

main = forM [10,20,40,80] $ \pic -> do
  let cdim = 10; cc = 3
  l1 <- getStdRandom (testData cdim pic cc)
  l2 <- getStdRandom (testData cdim pic cc)
  let (eps,minpts) = testParams cdim pic
      neigh = testNeighbor eps
      sem   = dbscanGcilSimple (stkEmpty :: Circuit.Stack.Stack NetUInt)
      nem   = dbscanGcilSimple (stkEmpty :: SimpleStack NetUInt)
      n     = 2*cc*pic
  packAndTest ("dbscan"++show n) l1 l2 $ sem neigh minpts
  packAndTest ("dbscanSimple"++show n) l1 l2 $ nem neigh minpts
