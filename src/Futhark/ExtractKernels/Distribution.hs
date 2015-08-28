{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
module Futhark.ExtractKernels.Distribution
       (
         Target
       , Targets
       , ppTargets
       , singleTarget
       , innerTarget
       , outerTarget
       , pushOuterTarget
       , pushInnerTarget

       , LoopNesting (..)

       , Nesting (..)
       , Nestings
       , ppNestings
       , letBindInInnerNesting
       , singleNesting
       , pushInnerNesting

       , KernelNest
       , kernelNestWidths
       , constructKernel

       , tryDistribute
       , tryDistributeBinding

       , SeqLoop (..)
       , interchangeLoops
       )
       where

import Control.Applicative
import Control.Monad.RWS.Strict
import Control.Monad.Trans.Maybe
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.Maybe
import Data.List
import Data.Ord
import Debug.Trace

import Futhark.Representation.AST.Attributes.Aliases
import Futhark.Representation.Basic
import Futhark.MonadFreshNames
import Futhark.Tools
import Futhark.Util
import Futhark.Renamer
import qualified Futhark.Analysis.Alias as Alias

import Prelude

type Target = (Pattern, Result)

-- ^ First pair element is the very innermost ("current") target.  In
-- the list, the outermost target comes first.
type Targets = (Target, [Target])

ppTargets :: Targets -> String
ppTargets (target, targets) =
  unlines $ map ppTarget $ targets ++ [target]
  where ppTarget (pat, res) =
          pretty pat ++ " <- " ++ pretty res

singleTarget :: Target -> Targets
singleTarget = (,[])

innerTarget :: Targets -> Target
innerTarget = fst

outerTarget :: Targets -> Target
outerTarget (inner_target, []) = inner_target
outerTarget (_, outer_target : _) = outer_target

pushOuterTarget :: Target -> Targets -> Targets
pushOuterTarget target (inner_target, targets) =
  (inner_target, target : targets)

pushInnerTarget :: Target -> Targets -> Targets
pushInnerTarget target (inner_target, targets) =
  (target, targets ++ [inner_target])

data LoopNesting = MapNesting { loopNestingPattern :: Pattern
                              , loopNestingCertificates :: Certificates
                              , loopNestingWidth :: SubExp
                              , loopNestingIndex :: VName
                              , loopNestingParamsAndArrs :: [(LParam, VName)]
                              }
                 deriving (Show)

ppLoopNesting :: LoopNesting -> String
ppLoopNesting (MapNesting _ _ _ _ params_and_arrs) =
  pretty (map fst params_and_arrs) ++
  " <- " ++
  pretty (map snd params_and_arrs)

loopNestingParams :: LoopNesting -> [LParam]
loopNestingParams  = map fst . loopNestingParamsAndArrs

instance FreeIn LoopNesting where
  freeIn (MapNesting pat cs w _ params_and_arrs) =
    freeInPattern pat <>
    freeIn cs <>
    freeIn w <>
    freeIn params_and_arrs

consumedIn :: LoopNesting -> Names
consumedIn (MapNesting pat _ _ _ params_and_arrs) =
  consumedInPattern pat <>
  mconcat (map (vnameAliases . snd)
           (filter (unique . paramType . fst) params_and_arrs))

data Nesting = Nesting { nestingLetBound :: Names
                       , nestingLoop :: LoopNesting
                       }
             deriving (Show)

letBindInNesting :: Names -> Nesting -> Nesting
letBindInNesting newnames (Nesting oldnames loop) =
  Nesting (oldnames <> newnames) loop

-- ^ First pair element is the very innermost ("current") nest.  In
-- the list, the outermost nest comes first.
type Nestings = (Nesting, [Nesting])

ppNestings :: Nestings -> String
ppNestings (nesting, nestings) =
  unlines $ map ppNesting $ nestings ++ [nesting]
  where ppNesting (Nesting _ loop) =
          ppLoopNesting loop

singleNesting :: Nesting -> Nestings
singleNesting = (,[])

pushInnerNesting :: Nesting -> Nestings -> Nestings
pushInnerNesting nesting (inner_nesting, nestings) =
  (nesting, nestings ++ [inner_nesting])

-- | Both parameters and let-bound.
boundInNesting :: Nesting -> Names
boundInNesting nesting =
  HS.fromList (loopNestingIndex loop : map paramName (loopNestingParams loop)) <>
  nestingLetBound nesting
  where loop = nestingLoop nesting

letBindInInnerNesting :: Names -> Nestings -> Nestings
letBindInInnerNesting names (nest, nestings) =
  (letBindInNesting names nest, nestings)


-- | Note: first element is *outermost* nesting.  This is different
-- from the similar types elsewhere!
type KernelNest = (LoopNesting, [LoopNesting])

-- | Add new outermost nesting, pushing the current outermost to the
-- list, also taking care to swap patterns if necessary.
pushKernelNesting :: Target -> LoopNesting -> KernelNest -> KernelNest
pushKernelNesting target newnest (nest, nests) =
  (fixNestingPatternOrder newnest target (loopNestingPattern nest),
   nest : nests)

fixNestingPatternOrder :: LoopNesting -> Target -> Pattern -> LoopNesting
fixNestingPatternOrder nest (_,res) inner_pat =
  nest { loopNestingPattern = basicPattern' [] pat' }
  where pat = loopNestingPattern nest
        pat' = map fst fixed_target
        fixed_target = sortBy (comparing posInInnerPat) $ zip (patternValueIdents pat) res
        posInInnerPat (_, Var v) = fromMaybe 0 $ elemIndex v $ patternNames inner_pat
        posInInnerPat _          = 0

newKernel :: LoopNesting -> KernelNest
newKernel nest = (nest, [])

kernelNestLoops :: KernelNest -> [LoopNesting]
kernelNestLoops (loop, loops) = loop : loops

kernelNestWidths :: KernelNest -> [SubExp]
kernelNestWidths = map loopNestingWidth . kernelNestLoops

constructKernel :: MonadFreshNames m =>
                   KernelNest -> Body -> m ([Binding], Binding)
constructKernel kernel_nest inner_body = do
  (w_bnds, w, ispace, inps, rts) <- constructKernel' kernel_nest
  let rank = length ispace
      returns = [ (rt, [0..rank + arrayRank rt - 1]) | rt <- rts ]
  index <- newVName "kernel_thread_index"
  return (w_bnds,
          Let (loopNestingPattern first_nest) () $ LoopOp $
          Kernel (loopNestingCertificates first_nest) w index ispace inps returns inner_body)
  where
    first_nest = fst kernel_nest

    constructKernel' (MapNesting pat _ nesting_w i params_and_arrs, []) =
      return ([], nesting_w, [(i,nesting_w)], inps, map rowType $ patternTypes pat)
      where inps = [ KernelInput (Param (paramIdent param) ()) arr [Var i] |
                     (param, arr) <- params_and_arrs ]

    constructKernel' (MapNesting _ _ nesting_w i params_and_arrs, nest : nests) = do
      (w_bnds, w, ispace, inps, returns) <- constructKernel' (nest, nests)

      w' <- newVName "kernel_w"
      let w_bnd = mkLet' [] [Ident w' $ Basic Int] $
                  PrimOp $ BinOp Times w nesting_w Int

      let inps' = map fixupInput inps
          isParam inp =
            snd <$> find ((==kernelInputArray inp) . paramName . fst) params_and_arrs
          fixupInput inp
            | Just arr <- isParam inp =
                inp { kernelInputArray = arr
                    , kernelInputIndices = Var i : kernelInputIndices inp }
            | otherwise =
                inp

      return (w_bnds++[w_bnd], Var w', (i, nesting_w) : ispace, extra_inps <> inps', returns)
      where extra_inps =
              [ KernelInput (Param (paramIdent param `setIdentUniqueness` Nonunique) ()) arr [Var i] |
                (param, arr) <- params_and_arrs ]

-- | Description of distribution to do.
data DistributionBody = DistributionBody {
    distributionTarget :: Targets
  , distributionFreeInBody :: Names
  , distributionConsumedInBody :: Names
  , distributionIdentityMap :: HM.HashMap VName Ident
  , distributionExpandTarget :: Target -> Target
    -- ^ Also related to avoiding identity mapping.
  }

distributionInnerPattern :: DistributionBody -> Pattern
distributionInnerPattern = fst . innerTarget . distributionTarget

distributionBodyFromBindings :: Targets -> [Binding] -> (DistributionBody, Result)
distributionBodyFromBindings ((inner_pat, inner_res), targets) bnds =
  let bound_by_bnds = boundByBindings bnds
      (inner_pat', inner_res', inner_identity_map, inner_expand_target) =
        removeIdentityMappingGeneral bound_by_bnds inner_pat inner_res
  in (DistributionBody
      { distributionTarget = ((inner_pat', inner_res'), targets)
      , distributionFreeInBody = mconcat (map freeInBinding bnds)
                                 `HS.difference` bound_by_bnds
      , distributionConsumedInBody =
        mconcat (map (consumedInBinding . Alias.analyseBinding) bnds)
        `HS.difference` bound_by_bnds
      , distributionIdentityMap = inner_identity_map
      , distributionExpandTarget = inner_expand_target
      },
      inner_res')

distributionBodyFromBinding :: Targets -> Binding -> (DistributionBody, Result)
distributionBodyFromBinding targets bnd =
  distributionBodyFromBindings targets [bnd]

createKernelNest :: (MonadFreshNames m, HasTypeEnv m) =>
                    Nestings
                 -> DistributionBody
                 -> m (Maybe (Targets, KernelNest))
createKernelNest (inner_nest, nests) distrib_body = do
  let (target, targets) = distributionTarget distrib_body
  unless (length nests == length targets) $
    fail $ "Nests and targets do not match!\n" ++
    "nests: " ++ ppNestings (inner_nest, nests) ++
    "\ntargets:" ++ ppTargets (target, targets)
  runMaybeT $ liftM prepare $ recurse $ zip nests targets

  where prepare (x, _, _, z) = (z, x)
        bound_in_nest =
          mconcat $ map boundInNesting $ inner_nest : nests
        -- | Can something of this type be taken outside the nest?
        -- I.e. are none of its dimensions bound inside the nest.
        distributableType =
          HS.null . HS.intersection bound_in_nest . freeIn . arrayDims

        distributeAtNesting :: (HasTypeEnv m, MonadFreshNames m) =>
                               Nesting
                            -> Pattern
                            -> (LoopNesting -> KernelNest, Names, Names)
                            -> HM.HashMap VName Ident
                            -> [Ident]
                            -> (Target -> Targets)
                            -> MaybeT m (KernelNest, Names, Names, Targets)
        distributeAtNesting
          (Nesting nest_let_bound nest)
          pat
          (add_to_kernel, free_in_kernel, consumed_in_kernel)
          identity_map
          inner_returned_arrs
          addTarget = do
          let nest'@(MapNesting _ cs w i params_and_arrs) =
                removeUnusedNestingParts free_in_kernel nest
              (params,arrs) = unzip params_and_arrs
              param_names = HS.fromList $ map paramName params
              free_in_kernel' =
                (freeIn nest' <> free_in_kernel) `HS.difference` param_names
              required_from_nest =
                free_in_kernel' `HS.intersection` nest_let_bound

          required_from_nest_idents <-
            forM (HS.toList required_from_nest) $ \name -> do
              t <- lift $ lookupType name
              return $ Ident name t

          (free_params, free_arrs, bind_in_target) <-
            liftM unzip3 $
            forM (inner_returned_arrs++required_from_nest_idents) $
            \(Ident pname ptype) ->
              case HM.lookup pname identity_map of
                Nothing -> do
                  arr <- newIdent (baseString pname ++ "_r") $
                         arrayOfRow ptype w
                  return (Param (Ident pname ptype) (),
                          arr,
                          True)
                Just arr ->
                  return (Param (Ident pname ptype) (),
                          arr,
                          False)

          let free_arrs_pat =
                basicPattern [] $ map ((,BindVar) . snd) $
                filter fst $ zip bind_in_target free_arrs
              free_params_pat =
                map snd $ filter fst $ zip bind_in_target free_params

              (actual_params, actual_arrs) =
                (params++free_params,
                 arrs++map identName free_arrs)
              actual_param_names =
                HS.fromList $ map paramName actual_params

              nest'' =
                makeUnconsumedParametersNonunique consumed_in_kernel $
                removeUnusedNestingParts free_in_kernel $
                MapNesting pat cs w i $ zip actual_params actual_arrs

              free_in_kernel'' =
                (freeIn nest'' <> free_in_kernel) `HS.difference` actual_param_names

              consumed_in_kernel' =
                (consumedIn nest'' <> consumed_in_kernel) `HS.difference` actual_param_names

          unless (all (distributableType . paramType) $
                  loopNestingParams nest'') $
            fail "Would induce irregular array"
          return (add_to_kernel nest'',

                  free_in_kernel'',

                  consumed_in_kernel',

                  addTarget (free_arrs_pat, map (Var . paramName) free_params_pat))

        recurse :: (HasTypeEnv m, MonadFreshNames m) =>
                   [(Nesting,Target)]
                -> MaybeT m (KernelNest, Names, Names, Targets)
        recurse [] =
          distributeAtNesting
          inner_nest
          (distributionInnerPattern distrib_body)
          (newKernel,
           distributionFreeInBody distrib_body `HS.intersection` bound_in_nest,
           distributionConsumedInBody distrib_body `HS.intersection` bound_in_nest)
          (distributionIdentityMap distrib_body)
          [] $
          singleTarget . distributionExpandTarget distrib_body

        recurse ((nest, (pat,res)) : nests') = do
          (kernel@(outer, _), kernel_free, kernel_consumed, kernel_targets) <- recurse nests'

          let (pat', res', identity_map, expand_target) =
                removeIdentityMappingFromNesting
                (HS.fromList $ patternNames $ loopNestingPattern outer) pat res

          distributeAtNesting
            nest
            pat'
            (\k -> pushKernelNesting (pat',res') k kernel,
             kernel_free,
             kernel_consumed)
            identity_map
            (patternIdents $ fst $ outerTarget kernel_targets)
            ((`pushOuterTarget` kernel_targets) . expand_target)

makeUnconsumedParametersNonunique :: Names -> LoopNesting -> LoopNesting
makeUnconsumedParametersNonunique consumed (MapNesting pat cs w i params_and_arrs) =
  MapNesting pat cs w i $ map checkIfConsumed params_and_arrs
  where checkIfConsumed (param, arr)
          | paramName param `HS.member` consumed = (param, arr)
          | otherwise                            = (makeNonunique param, arr)
        makeNonunique param =
          param { paramIdent =
                     (paramIdent param)
                     { identType = setUniqueness (paramType param) Nonunique }
                }

removeUnusedNestingParts :: Names -> LoopNesting -> LoopNesting
removeUnusedNestingParts used (MapNesting pat cs w i params_and_arrs) =
  MapNesting pat cs w i $ zip used_params used_arrs
  where (params,arrs) = unzip params_and_arrs
        (used_params, used_arrs) =
          unzip $
          filter ((`HS.member` used) . paramName . fst) $
          zip params arrs

removeIdentityMappingGeneral :: Names -> Pattern -> Result
                             -> (Pattern,
                                 Result,
                                 HM.HashMap VName Ident,
                                 Target -> Target)
removeIdentityMappingGeneral bound pat res =
  let (identities, not_identities) =
        mapEither isIdentity $ zip (patternElements pat) res
      (not_identity_patElems, not_identity_res) = unzip not_identities
      (identity_patElems, identity_res) = unzip identities
      expandTarget (tpat, tres) =
        (Pattern [] $ patternElements tpat ++ identity_patElems,
         tres ++ map Var identity_res)
      identity_map = HM.fromList $ zip identity_res $
                      map patElemIdent identity_patElems
  in (Pattern [] not_identity_patElems,
      not_identity_res,
      identity_map,
      expandTarget)
  where isIdentity (patElem, Var v)
          | not (v `HS.member` bound) = Left (patElem, v)
        isIdentity x                  = Right x

removeIdentityMappingFromNesting :: Names -> Pattern -> Result
                                 -> (Pattern,
                                     Result,
                                     HM.HashMap VName Ident,
                                     Target -> Target)
removeIdentityMappingFromNesting bound_in_nesting pat res =
  let (pat', res', identity_map, expand_target) =
        removeIdentityMappingGeneral bound_in_nesting pat res
  in (pat', res', identity_map, expand_target)

tryDistribute :: (MonadFreshNames m, HasTypeEnv m) =>
                 Nestings -> Targets -> [Binding]
              -> m (Maybe (Targets, [Binding]))
tryDistribute _ targets [] =
  -- No point in distributing an empty kernel.
  return $ Just (targets, [])
tryDistribute nest targets bnds =
  createKernelNest nest dist_body >>=
  \case
    Just (targets', distributed) -> do
      (w_bnds, kernel_bnd) <- constructKernel distributed inner_body
      distributed' <- optimiseKernel <$> renameBinding kernel_bnd
      trace ("distributing\n" ++
             pretty (mkBody bnds $ snd $ innerTarget targets) ++
             "\nas\n" ++ pretty distributed' ++
             "\ndue to targets\n" ++ ppTargets targets ++
             "\nand with new targets\n" ++ ppTargets targets') return $
        Just (targets', w_bnds ++ [distributed'])
    Nothing ->
      return Nothing
  where (dist_body, inner_body_res) = distributionBodyFromBindings targets bnds
        inner_body = mkBody bnds inner_body_res

tryDistributeBinding :: (MonadFreshNames m, HasTypeEnv m) =>
                        Nestings -> Targets -> Binding
                     -> m (Maybe (Result, Targets, KernelNest))
tryDistributeBinding nest targets bnd =
  liftM addRes <$> createKernelNest nest dist_body
  where (dist_body, res) = distributionBodyFromBinding targets bnd
        addRes (targets', kernel_nest) = (res, targets', kernel_nest)

data SeqLoop = SeqLoop Pattern [VName] [(FParam, SubExp)] LoopForm Body

seqLoopBinding :: SeqLoop -> Binding
seqLoopBinding (SeqLoop pat ret merge form body) =
  Let pat () $ LoopOp $ DoLoop ret merge form body

interchangeLoop :: MonadBinder m =>
                   SeqLoop -> LoopNesting
                -> m SeqLoop
interchangeLoop
  (SeqLoop loop_pat ret merge form body)
  (MapNesting pat cs w i params_and_arrs) = do
    merge_expanded <- mapM expand merge

    let ret_params_mask = map ((`elem` ret) . paramName . fst) merge
        ret_expanded = [ paramName param
                       | ((param,_), used) <- zip merge_expanded ret_params_mask,
                         used]
        loop_pat_expanded =
          Pattern [] $ map expandPatElem $ patternElements loop_pat
        new_params = map fst merge
        new_arrs = map (paramName . fst) merge_expanded
        rettype = map rowType $ patternTypes loop_pat_expanded

    -- If the map consumes something that is bound outside the loop
    -- (i.e. is not a merge parameter), we have to copy() it.  As a
    -- small simplification, we just remove the parameter outright if
    -- it is not used anymore.  This might happen if the parameter was
    -- used just as the inital value of a merge parameter.
    ((params', arrs'), copy_bnds) <-
      runBinder $ bindingParamTypes new_params $
      unzip <$> catMaybes <$> mapM copyOrRemoveParam params_and_arrs

    let lam = Lambda i (params'<>new_params) body rettype
        map_bnd = Let loop_pat_expanded () $
                  LoopOp $ Map cs w lam $ arrs' <> new_arrs
        res = map Var $ patternNames loop_pat_expanded

    return $
      SeqLoop pat ret_expanded merge_expanded form $
      mkBody (copy_bnds++[map_bnd]) res
  where free_in_body = freeInBody body

        copyOrRemoveParam (param, arr)
          | not (paramName param `HS.member` free_in_body) =
            return Nothing
          | unique $ paramType param = do
              arr' <- newVName $ baseString arr <> "_interchange_copy"
              let arr_t = arrayOfRow (paramType param) w
              addBinding $
                Let (basicPattern' [] [Ident arr' arr_t]) () $
                PrimOp $ Copy arr
              return $ Just (param, arr')
          | otherwise =
            return $ Just (param, arr)

        expandedInit _ (Var v)
          | Just arr <- snd <$> find ((==v).paramName.fst) params_and_arrs =
              return $ Var arr
        expandedInit param_name se =
          letSubExp (param_name <> "_expanded_init") $
            PrimOp $ Replicate w se

        expand (merge_param, merge_init) = do
          expanded_param <-
            newIdent (param_name <> "_expanded") $
            arrayOfRow (paramType merge_param) w
          expanded_init <- expandedInit param_name merge_init
          return (Param expanded_param (), expanded_init)
            where param_name = baseString $ paramName merge_param

        expandPatElem patElem =
          patElem { patElemIdent = expandIdent $ patElemIdent patElem }

        expandIdent ident =
          ident { identType = arrayOfRow (identType ident) w }

interchangeLoops :: (MonadFreshNames m, HasTypeEnv m) =>
                    KernelNest -> SeqLoop
                 -> m [Binding]

interchangeLoops nest loop = do
  (loop', bnds) <-
    runBinder $ foldM interchangeLoop loop $ reverse $ kernelNestLoops nest
  return $ bnds ++ [seqLoopBinding loop']

optimiseKernel :: Binding -> Binding
optimiseKernel bnd = fromMaybe bnd $ tryOptimiseKernel bnd

tryOptimiseKernel :: Binding -> Maybe Binding
tryOptimiseKernel bnd = kernelIsRearrange bnd <|>
                        kernelIsReshape bnd <|>
                        kernelIsCopy bnd

singleBindingBody :: Body -> Maybe Binding
singleBindingBody (Body _ [bnd] [res])
  | [res] == map Var (patternNames $ bindingPattern bnd) =
      Just bnd
singleBindingBody _ = Nothing

singleExpBody :: Body -> Maybe Exp
singleExpBody = liftM bindingExp . singleBindingBody

fullIndexInput :: [(VName, SubExp)] -> [KernelInput lore]
               -> Maybe (KernelInput lore)
fullIndexInput ispace =
  find $ (==map (Var . fst) ispace) . kernelInputIndices

kernelIsRearrange :: Binding -> Maybe Binding
kernelIsRearrange (Let outer_pat _
                   (LoopOp (Kernel outer_cs _ _ ispace [inp] [_] body)))
  | Just (PrimOp (Rearrange inner_cs perm arr)) <- singleExpBody body,
    map (Var . fst) ispace == kernelInputIndices inp,
    arr == kernelInputName inp =
      let rank = length ispace
          cs' = outer_cs ++ inner_cs
          perm' = [0..rank-1] ++ map (rank+) perm
      in Just $ Let outer_pat () $
         PrimOp $ Rearrange cs' perm' $ kernelInputArray inp
kernelIsRearrange _ = Nothing

kernelIsReshape :: Binding -> Maybe Binding
kernelIsReshape (Let (Pattern [] [outer_patElem]) ()
                 (LoopOp (Kernel outer_cs _ _ ispace inps [_] body)))
  | Just (PrimOp (Reshape inner_cs new_inner_shape arr)) <- singleExpBody body,
    Just inp <- fullIndexInput ispace inps,
    map (Var . fst) ispace == kernelInputIndices inp,
    arr == kernelInputName inp =
      let new_outer_shape =
            take (length new_shape - length new_inner_shape) new_shape
          cs' = outer_cs ++ inner_cs
      in Just $ Let (Pattern [] [outer_patElem]) () $
         PrimOp $ Reshape cs' (map DimCoercion new_outer_shape ++ new_inner_shape) $
         kernelInputArray inp
  where new_shape = arrayDims $ patElemType outer_patElem
kernelIsReshape _ = Nothing

kernelIsCopy :: Binding -> Maybe Binding
kernelIsCopy (Let pat ()
              (LoopOp (Kernel _ _ _ ispace inps [_] body)))
  | Just (PrimOp (Copy arr)) <- singleExpBody body,
    Just inp <- fullIndexInput ispace inps,
    map (Var . fst) ispace == kernelInputIndices inp,
    arr == kernelInputName inp =
      Just $ Let pat () $
      PrimOp $ Copy $ kernelInputArray inp
kernelIsCopy _ = Nothing