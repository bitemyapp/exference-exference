{-# LANGUAGE PatternGuards #-}

module Language.Haskell.Exference.FunctionDecl
  ( HsFunctionDecl
  , RatedHsFunctionDecl
  , declToBinding
  )
where



import Language.Haskell.Exference.FunctionBinding
import Language.Haskell.Exference.Types
import Language.Haskell.Exference.TypeUtils
import Language.Haskell.Exference.Expression



type HsFunctionDecl = (QualifiedName, HsType)
type RatedHsFunctionDecl = (QualifiedName, Float, HsType)
                            -- name, rating, type

declToBinding :: RatedHsFunctionDecl -> FunctionBinding
declToBinding (a,r,t) =
  (result, a, r, constrs, params)
 where
  (result, params, _, constrs) = splitArrowResultParams t
