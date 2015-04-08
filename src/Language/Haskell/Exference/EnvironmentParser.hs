module Language.Haskell.Exference.EnvironmentParser
  ( parseModules
  , parseModulesSimple
  , environmentFromModuleAndRatings
  , haskellSrcExtsParseMode
  , compileWithDict
  , ratingsFromFile
  )
where



import Language.Haskell.Exference
import Language.Haskell.Exference.ExpressionToHaskellSrc
import Language.Haskell.Exference.BindingsFromHaskellSrc
import Language.Haskell.Exference.ClassEnvFromHaskellSrc
import Language.Haskell.Exference.TypeFromHaskellSrc
import Language.Haskell.Exference.FunctionBinding
import Language.Haskell.Exference.FunctionDecl

import Language.Haskell.Exference.ConstrainedType
import Language.Haskell.Exference.Type
import Language.Haskell.Exference.SimpleDict
import Language.Haskell.Exference.TypeClasses
import Language.Haskell.Exference.Expression
import Language.Haskell.Exference.ExferenceStats

import Control.DeepSeq

import System.Process

import Control.Applicative ( (<$>), (<*>), (<*) )
import Control.Arrow ( second, (***) )
import Control.Monad ( when, forM_, guard, forM, mplus, mzero )
import Data.List ( sortBy, find )
import Data.Ord ( comparing )
import Text.Printf
import Data.Maybe ( listToMaybe, fromMaybe, maybeToList )
import Data.Either ( lefts, rights )
import Control.Monad.Writer.Strict

import Language.Haskell.Exts.Syntax ( Module(..), Decl(..), ModuleName(..) )
import Language.Haskell.Exts.Parser ( parseModuleWithMode
                                    , parseModule
                                    , ParseResult (..)
                                    , ParseMode (..)
                                    , defaultParseMode )
import Language.Haskell.Exts.Extension ( Language (..)
                                       , Extension (..)
                                       , KnownExtension (..) )

import Control.Arrow ( first )
import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Char

import qualified Data.Map as M


builtInDecls :: [HsFunctionDecl]
builtInDecls = 
  ("(:)", HsConstrainedType [] (TypeArrow
                                 (TypeVar 0)
                                 (TypeArrow (TypeApp (TypeCons "List")
                                                     (TypeVar 0))
                                            (TypeApp (TypeCons "List")
                                                     (TypeVar 0)))))
  : map (second $ readConstrainedType emptyClassEnv)
    [ (,) "()" "Unit"
    , (,) "(,)" "a -> b -> Tuple2 a b"
    , (,) "(,,)" "a -> b -> c -> Tuple3 a b c"
    , (,) "(,,,)" "a -> b -> c -> d -> Tuple4 a b c d"
    , (,) "(,,,,)" "a -> b -> c -> d -> e -> Tuple5 a b c d e"
    , (,) "(,,,,,)" "a -> b -> c -> d -> e -> f -> Tuple6 a b c d e f"
    , (,) "(,,,,,,)" "a -> b -> c -> d -> e -> f -> g -> Tuple7 a b c d e f g"
    ]

builtInDeconstructors :: [DeconstructorBinding]
builtInDeconstructors = map helper ds
 where
  helper (t, xs) = ( read t
                   , [ (n, read <$> ts)
                       |(n, ts) <- xs]
                   , False
                   )
  ds = [ (,) "Tuple2 a b" [("(,)", ["a", "b"])]
       , (,) "Tuple3 a b c" [("(,,)", ["a", "b", "c"])]
       , (,) "Tuple4 a b c d" [("(,,,)", ["a", "b", "c", "d"])]
       , (,) "Tuple5 a b c d e" [("(,,,,)", ["a", "b", "c", "d", "e"])]
       , (,) "Tuple6 a b c d e f" [("(,,,,,)", ["a", "b", "c", "d", "e", "f"])]
       , (,) "Tuple7 a b c d e f g" [("(,,,,,,)", ["a", "b", "c", "d", "e", "f", "g"])]
       ]

-- | Takes a list of bindings, and a dictionary of desired
-- functions and their rating, and compiles a list of
-- RatedFunctionBindings.
-- 
-- If a function in the dictionary is not in the list of bindings,
-- Left is returned with the corresponding name.
--
-- Otherwise, the result is Right.
compileWithDict :: [(String, Float)]
                -> [HsFunctionDecl]
                -> Either String [RatedHsFunctionDecl]
                -- function_not_found or all bindings
compileWithDict ratings binds = forM ratings $ \(name, rating) ->
  case find ((name==).fst) binds of
    Nothing -> Left name
    Just (_,t) -> Right (name, rating, t)

-- | input: a list of filenames for haskell modules and the
-- parsemode to use for it.
--
-- output: the environment extracted from these modules, wrapped
-- in a Writer that contains warnings/errors.
parseModules :: [(ParseMode, String)]
             -> IO (Writer
                      [String]
                      ( [HsFunctionDecl]
                      , [DeconstructorBinding]
                      , StaticClassEnv))
parseModules l = do
  rawTuples <- mapM hRead l
  let eParsed = map hParse rawTuples
  {-
  let h :: Decl -> IO ()
      h i@(InstDecl _ _ _ _ _ _ _) = do
        pprint i >>= print
      h _ = return ()
  forM_ (rights eParsed) $ \(Module _ _ _ _ _ _ ds) ->
    forM_ ds h
  -}
  -- forM_ (rights eParsed) $ \m -> pprintTo 10000 m >>= print
  return $ do
    mapM_ (tell.return) $ lefts eParsed
    let mods = rights eParsed
    (cntxt@(StaticClassEnv clss insts), n_insts) <- getClassEnv mods
    -- TODO: try to exfere this stuff
    (decls, deconss) <- do
      stuff <- mapM (hExtractBinds cntxt) mods
      return $ concat *** concat $ unzip stuff
    tell ["got " ++ show (length clss) ++ " classes"]
    tell ["and " ++ show (n_insts) ++ " instances"]
    tell ["(-> " ++ show (length $ concat $ M.elems $ insts) ++ " instances after inflation)"]
    tell ["and " ++ show (length decls) ++ " function decls"]
    return $ ( builtInDecls++decls
             , builtInDeconstructors++deconss
             , cntxt
             )
  where
    hRead :: (ParseMode, String) -> IO (ParseMode, String)
    hRead (mode, s) = (,) mode <$> readFile s
    hParse :: (ParseMode, String) -> Either String Module
    hParse (mode, content) = case parseModuleWithMode mode content of
      f@(ParseFailed _ _) -> Left $ show f
      ParseOk modul       -> Right modul
    hExtractBinds :: StaticClassEnv
                  -> Module
                  -> Writer [String] ([HsFunctionDecl], [DeconstructorBinding])
    hExtractBinds cntxt modul@(Module _ (ModuleName _mname) _ _ _ _ _) = do
      -- tell $ return $ mname
      let eFromData = getDataConss modul
          eDecls = getDecls cntxt modul
                 ++ getClassMethods cntxt modul
      mapM_ (tell.return) $ lefts eFromData ++ lefts eDecls
      -- tell $ map show $ rights ebinds
      let (binds1s, deconss) = unzip $ rights eFromData
          binds2 = rights eDecls
      return $ ( concat binds1s ++ binds2, deconss )

-- | A simplified version of environmentFromModules where the input
-- is just one module, parsed with some default ParseMode;
-- the output is transformed so that all functionsbindings get
-- a rating of 0.0.
parseModulesSimple :: String
                   -> IO (Writer
                        [String]
                        ( [RatedHsFunctionDecl]
                        , [DeconstructorBinding]
                        , StaticClassEnv) )
parseModulesSimple s = (helper <$>)
                   <$> parseModules [(haskellSrcExtsParseMode s, s)]
 where
  addRating (a,b) = (a,0.0,b)
  helper (decls, deconss, cntxt) = (addRating <$> decls, deconss, cntxt)

haskellSrcExtsParseMode :: String -> ParseMode
haskellSrcExtsParseMode s = ParseMode (s++".hs")
                                      Haskell2010
                                      exts2
                                      False
                                      False
                                      Nothing
  where
    exts1 = [ TypeOperators
            , ExplicitForAll
            , ExistentialQuantification
            , TypeFamilies
            , FunctionalDependencies
            , FlexibleContexts
            , MultiParamTypeClasses ]
    exts2 = map EnableExtension exts1

ratingsFromFile :: String -> IO (Either String [(String, Float)])
ratingsFromFile s = do
  content <- readFile s
  let
    parser =
      (many $ try $ do
        spaces
        name <- many1 (noneOf " ")
        _ <- space
        spaces
        _ <- char '='
        spaces
        minus <- optionMaybe $ char '-'
        a <- many1 digit
        b <- char '.'
        c <- many1 digit
        case minus of
          Nothing -> return (name, read $ a++b:c)
          Just _  -> return (name, read $ '-':a++b:c))
      <* spaces
  return $ case runParser parser () "" content of
    Left e -> Left $ show e
    Right x -> Right x

-- TODO: add warnings for ratings not applied
environmentFromModuleAndRatings :: String
                            -> String
                            -> IO (Writer
                                [String]
                                ( [FunctionBinding]
                                , [DeconstructorBinding]
                                , StaticClassEnv) )
environmentFromModuleAndRatings s1 s2 = do
  let exts1 = [ TypeOperators
              , ExplicitForAll
              , ExistentialQuantification
              , TypeFamilies
              , FunctionalDependencies
              , FlexibleContexts
              , MultiParamTypeClasses ]
      exts2 = map EnableExtension exts1
      mode = ParseMode (s1++".hs")
                       Haskell2010
                       exts2
                       False
                       False
                       Nothing
  w <- parseModules [(mode, s1)]
  r <- ratingsFromFile s2
  return $ do
    (decls, deconss, cntxt) <- w
    case r of
      Left e -> do
        tell ["could not parse ratings!",e]
        return ([], [], cntxt)
      Right x -> do
        let f (a,b) = declToBinding
                    $ ( a
                      , fromMaybe 0.0 (lookup a x)
                      , b
                      )
        return $ (map f decls, deconss, cntxt)
