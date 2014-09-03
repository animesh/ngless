{-# LANGUAGE OverloadedStrings #-}

module Annotation
    ( AnnotationIntersectionMode(..)
    , annotate
    , _intersection_strict
    , _intersection_non_empty
    , _filterFeatures
    , _sizeNoDup
    ) where


import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Text as T

import qualified Data.IntervalMap.Strict as IM

import qualified Data.Set as Set
import qualified Data.Map.Strict as M

import Data.Maybe (fromMaybe, fromJust)
import Data.List (foldl')

import FileManagement(readPossiblyCompressedFile)
import ReferenceDatabases
import Configuration

import Data.GFF
import Data.Sam (SamLine(..), isAligned, isPositive, cigarTLen, readAlignments)
import Data.AnnotRes

data AnnotationIntersectionMode = IntersectUnion | IntersectStrict | IntersectNonEmpty
    deriving (Eq, Show)

annotate :: FilePath -> Maybe FilePath -> Maybe [String] -> Maybe T.Text -> AnnotationIntersectionMode -> Bool -> Bool -> IO FilePath
annotate samFP (Just g) feats _ m a s = do
    printNglessLn (concat ["annotate with GFF: ", g])
    annotate' samFP g feats (getIntervalQuery m) a s  -- ignore default GFF
annotate samFP Nothing feats dDs m a s =
    printNglessLn (concat ["annotate with default GFF: ", show . fromJust $ dDs]) >>
        case dDs of
            Just v  -> do
                basedir <- ensureDataPresent (T.unpack v)
                annotate' samFP (getGff basedir) feats (getIntervalQuery m) a s   -- used default GFF
            Nothing -> error("A gff must be provided by using the argument 'gff'") -- not default ds and no gff passed as arg

getIntervalQuery :: AnnotationIntersectionMode -> ([IM.IntervalMap Int [GffCount]] -> IM.IntervalMap Int [GffCount])
getIntervalQuery IntersectUnion = union
getIntervalQuery IntersectStrict = _intersection_strict
getIntervalQuery IntersectNonEmpty = _intersection_non_empty


annotate' :: FilePath -> FilePath -> Maybe [String] -> ([IM.IntervalMap Int [GffCount]] -> IM.IntervalMap Int [GffCount]) -> Bool -> Bool -> IO FilePath
annotate' samFp gffFp feats a f s = do
    gff <- readPossiblyCompressedFile gffFp
    sam <- readPossiblyCompressedFile samFp
    let imGff = intervals . filter (_filterFeatures feats) . readAnnotations $ gff
        counts = compStatsAnnot imGff sam f a s
    writeAnnotCount samFp (toGffM . concat . map (M.elems) . M.elems $ counts)

toGffM :: [IM.IntervalMap Int [GffCount]] -> [GffCount]
toGffM = concat . foldl (\a b -> (++) (IM.elems b) a) []


type AnnotationMap = M.Map GffType (M.Map S8.ByteString (IM.IntervalMap Int [GffCount]))
compStatsAnnot ::  AnnotationMap -> L8.ByteString -> Bool -> ([IM.IntervalMap Int [GffCount]] -> IM.IntervalMap Int [GffCount]) -> Bool -> AnnotationMap
compStatsAnnot imGff sam a f s = foldl iterSam imGff $ filter isAligned . readAlignments $ sam
    where
      iterSam im y = M.map (M.alter alterCounts k) im
        where
            alterCounts Nothing = Nothing
            alterCounts (Just v) = Just $ modeAnnotation f a v y s
            k = samRName y


modeAnnotation :: ([IM.IntervalMap Int [GffCount]] -> IM.IntervalMap Int [GffCount]) -> Bool -> IM.IntervalMap Int [GffCount] -> SamLine -> Bool -> IM.IntervalMap Int [GffCount]
modeAnnotation f a im y s = countsAmbiguity a ((filterStrand s asStrand) . f $ posR) im
  where
    sStart = samPos y
    sEnd   = sStart + (cigarTLen $ samCigar y) - 1
    posR   = map (\k -> IM.fromList $ IM.containing im k) [sStart..sEnd]
    asStrand = if isPositive y then GffPosStrand else GffNegStrand

filterStrand :: Bool -> GffStrand -> IM.IntervalMap Int [GffCount] -> IM.IntervalMap Int [GffCount]
filterStrand True  s m =  IM.filter (not . null) . IM.map (filterByStrand s) $ m
filterStrand False _ m = m

countsAmbiguity :: Bool -> IM.IntervalMap Int [GffCount] -> IM.IntervalMap Int [GffCount] -> IM.IntervalMap Int [GffCount]
countsAmbiguity True toU imR = uCounts toU imR
countsAmbiguity False toU imR = case IM.size toU of
        0 -> imR --"no_feature"
        _ -> case _sizeNoDup toU of
            1 -> uCounts (IM.fromList . remAllButOneCount . IM.toList $ toU) imR -- same feature multiple times. increase that feature ONCE.
            _ -> imR --'ambiguous'
    where
        remAllButOneCount = take 1 -- [(k1,[v1,v2,v3]), (k2,[v1,v2,v3])] -> [(K, _)] -- only for the case where all ids are equal.


uCounts :: IM.IntervalMap Int [GffCount] -> IM.IntervalMap Int [GffCount] -> IM.IntervalMap Int [GffCount]
uCounts keys im = IM.foldlWithKey (\res k _ -> IM.adjust (incCount) k res) im keys
    where
        incCount []     = []
        incCount (x:rs) = incCount' x : rs
        incCount' (GffCount gId gT gC gS) = (GffCount gId gT (gC + 1) gS)


--- Diferent modes

union :: [IM.IntervalMap Int [GffCount]] -> IM.IntervalMap Int [GffCount]
union = IM.unions

_intersection_strict :: [IM.IntervalMap Int [GffCount]] -> IM.IntervalMap Int [GffCount]
_intersection_strict [] = IM.empty
_intersection_strict im = foldl (IM.intersection) (head im) im

_intersection_non_empty :: [IM.IntervalMap Int [GffCount]] -> IM.IntervalMap Int [GffCount]
_intersection_non_empty im = _intersection_strict . filter (not . IM.null) $ im

--------------------

_sizeNoDup :: IM.IntervalMap Int [GffCount] -> Int
_sizeNoDup im = Set.size $ IM.foldl (\m v -> Set.union m (gffIds v)) Set.empty im -- 1 (same feature) or n dif features.
    where
        gffIds :: [GffCount] -> Set.Set S8.ByteString
        gffIds = Set.fromList . map annotSeqId
--------------------

intervals :: [GffLine] -> M.Map GffType (M.Map S8.ByteString (IM.IntervalMap Int [GffCount]))
intervals = foldl' insertg M.empty
    where
        insertg im g = M.alter (\mF -> updateF g mF) (gffType g) im
        updateF g mF = case mF of
            Nothing  -> Just $ updateF' g M.empty
            Just mF' -> Just $ updateF' g mF'

        updateF' g mF = M.alter (\v -> updateChrMap g v) (gffSeqId g) mF
        updateChrMap g v  = case v of
            Nothing -> Just $ insertCount g IM.empty
            Just a  -> Just $ insertCount g a

insertCount :: GffLine -> IM.IntervalMap Int [GffCount] -> IM.IntervalMap Int [GffCount]
insertCount g im = IM.insertWith ((++)) (asInterval g) [GffCount (genId g) (gffType g) 0 (gffStrand g)] im


asInterval :: GffLine -> IM.Interval Int
asInterval g = IM.ClosedInterval (gffStart g) (gffEnd g)

genId :: GffLine -> S8.ByteString
genId g = fromMaybe (S8.pack "unknown") $ gffGeneId g

_filterFeatures :: Maybe [String] -> GffLine -> Bool
_filterFeatures Nothing gf = (gffType gf) == GffGene
_filterFeatures (Just fs) gf = any matchFeature fs
    where
        g = gffType gf
        matchFeature "gene" = g == GffGene
        matchFeature "exon" = g == GffExon
        matchFeature "cds"  = g == GffCDS
        matchFeature "CDS"  = g == GffCDS
        matchFeature s = (show g) == s
