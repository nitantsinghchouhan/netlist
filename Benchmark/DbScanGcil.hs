
import Control.Monad
import Data.Map as M

import Circuit.NetList
import Circuit.NetList.Gcil
import qualified Circuit.Stack as Stk
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
    clus' = dbscanExpand neighbor minpts clus cc' l i

-- Assumes initKey is not an outlier
dbscanExpand neighbor minpts clusInit cc l initKey = aux clusInit [initKey]
  where
  asc = zip [0..] l
  aux clus [] = clus
  aux clus (i:is)
    | M.member i clus = aux clus  is
    | nc < minpts     = aux clus' is
    | otherwise       = aux clus' $ ne++is
    where
    clus' = M.insert i cc clus
    ne = [j | (j,x) <- asc, i/=j, neighbor x curx]
    nc = length ne
    curx = l!!i

-- The same depth-first algorithm presented above is now a circuit below
-- For more info, look at circitizeDbscan.txt

dbscanGcil neighbor minpts l = do
  let cc = constInt 0
      outerLoop = netTrue
      i = constIntW (indexSize n) 0
      stk = Stk.empty
      cluster = replicate n i

  (cluster,cc,_,_,_) <- foldM (\(cluster,cc,outerLoop,i,stk) _ -> do
    startExpand <- do c1 <- greaterThan (constInt n) i
                      c2 <- equal (constInt 0) =<< muxList i cluster
                      netAnds [outerLoop,c1,c2]
    checkNeighbor <- return startExpand
    cp <- return i
    stopExpand <- bind2 netAnd (netNot outerLoop) (Stk.null stk)
    outerLoop' <- netOr outerLoop stopExpand
    i <- condAdd stopExpand i (constInt 1)
    keepExpand <- netXor stopExpand =<< netNot outerLoop
    cur <- Stk.top stk
    stk <- Stk.condPop keepExpand stk
    unvisited <- netAnd keepExpand 
              =<< equal (constInt 0) =<< muxList cur cluster
    cluster <- naiveArrayWrite unvisited cur cc cluster
    checkNeighbor <- netOr checkNeighbor unvisited
    cp <- mux unvisited cp cur

    closeVec <- mapM (neighbor cp) l
    nc <- countTrue closeVec
    pc <- netAnd checkNeighbor =<< greaterThan nc (minpts-1)
    stk <- foldM (\(x,c) stk -> do c' <- netAnd c pc
                                   Stk.condPush c' x stk) stk l
    startExpand2 <- netAnd outerLoop pc
    cc <- condAdd startExpand2 cc (constInt 1)
    outerLoop' <- netAnd outerLoop' =<< netNot startExpand2

    return (cluster,cc,outerLoop',i,stk)
    ) (cluster,cc,outerLoop,i,stk) [1..2*n]
  return (cluster,cc)

  where n = length l

-- TODO eyeball this a little longer with circitize by the side
-- Make a new data maker. Fix data range. Run, debug, collect data.