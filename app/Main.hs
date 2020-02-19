module Main where

--import Data.List.Split (endBy, wordsBy)
import System.IO
import Data.Maybe
import Debug.Trace
import Data.List (intercalate, partition, lookup)
import Data.Char (toUpper)
import Text.ParserCombinators.ReadP
import System.Directory
import System.Environment

data HeaderItem 
    = Preproc String
    | Comment String
    | Fun (String, String) [(String, String)]
    | Var (String, String)
    deriving Show


isWhiteSpace = (flip elem) " \t\n"
isNameChar = not.(flip elem) " \t\n;,()"
readPreproc = fmap Preproc $ (char '#') >> manyTill get (char '\n')
readComment = fmap Comment $ (string "/*") >> manyTill get (string "*/")
readTypeName = skipSpaces
            >> sepBy (munch1 (isNameChar)) (skipMany1 $ satisfy isWhiteSpace) >>= \ws 
            -> case ws of
                  []  -> return ("void", "")
                  [a] -> return (a, "")
                  a   -> return ( intercalate " " (init a) ++ takeWhile (=='*') (last a)
                                , dropWhile (=='*') (last a) )
                    
readVar = readTypeName >>= \tn -> skipSpaces >> char ';' >> return (Var tn)
readFun = readTypeName >>= \tn 
       -> skipSpaces  
       >> char '(' >> sepBy readTypeName (char ',') >>= \args -> char ')' 
       >> skipSpaces >> char ';' 
       >> return (Fun tn args)


readHeaderItem = skipSpaces >> readPreproc <++ readComment <++ readFun <++ readVar
readHeader fn = fmap (fst . head 
            . (readP_to_S $ many readHeaderItem >>= \his 
                         -> skipSpaces >> eof >> return his)) 
            $ readFile fn

varTable = 
    [ ("int", "Int")
    , ("float", "Float")
    , ("double", "Double")
    , ("char", "CChar")
    , ("bool", "CBool")
    , ("void", "()")
    , ("int8_t" , "Int8")
    , ("int16_t", "Int16")
    , ("int32_t", "Int32")
    , ("int64_t", "Int64")
    , ("uint8_t" , "Word8")
    , ("uint16_t", "Word16")
    , ("uint32_t", "Word32")
    , ("uint64_t", "Word64")
    , ("size_t", "CSize")
    , ("cl_mem", "CLMem")
    , ("cl_command_queue", "CLCommandQueue") ]


varTable2 = 
    [ ("f32", "Float")
    , ("f64", "Double")
    , ("bool", "CBool")
    , ("i8" , "Int8")
    , ("i16", "Int16")
    , ("i32", "Int32")
    , ("i64", "Int64")
    , ("u8" , "Word8")
    , ("u16", "Word16")
    , ("u32", "Word32")
    , ("u64", "Word64") ]

capitalize (c:cs) = toUpper c:cs
wrapIfNotOneWord s = if elem ' ' s then "(" ++ s ++ ")" else s
haskellType s = 
    let pn = length $ dropWhile (/='*') s
        ts = dropWhile (=="const") $ words $ takeWhile (/='*') s
     in (intercalate "(" $ replicate pn "Ptr ") 
     ++ (if head ts == "struct" 
            then capitalize $ ts !! 1
            else (case lookup (head ts) varTable of 
                    Just s -> s; 
                    Nothing -> error $ "type " ++ s ++ "not found";))
     ++ replicate (pn-1) ')'

haskellDeclaration (Preproc s) = ""
haskellDeclaration (Comment s) 
    = intercalate "\n" 
    $ map (("--"++).drop 2) $ filter (/="") $ lines s 
haskellDeclaration (Var (_, n)) = "data " ++ capitalize n
haskellDeclaration (Fun (ot, name) args) 
    =  "foreign import ccall unsafe \"" ++ name ++ "\"\n  "
    ++ drop 8 name ++ "\n    :: "
    ++ intercalate "\n    -> " 
       ( (map haskellType $ filter (/="void") $ map fst args)
       ++ ["IO " ++ wrapIfNotOneWord (haskellType ot)] )
    ++ "\n"

rawImportString headerItems = intercalate "\n" $ map haskellDeclaration headerItems

instanceDeclarations (Var (_, n))
    =  (if isObject then objectString else "") 
    ++ (if isArray  then arrayString  else "")
    where cn = capitalize sn
          rn = capitalize n
          sn = drop 8 n
          isObject = take 7 sn /= "context" 
          isArray = isObject && take 6 sn /= "opaque"
          dim = if isArray 
                    then read $ (:[]) $ last $ init sn
                    else 0
          element = if isArray
                        then case lookup (takeWhile (/= '_') sn) varTable2 of
                                (Just t) -> t
                                Nothing  -> error $ "ArrayType" ++ sn ++ " not found."
                        else ""
          arrayString = "instance FutharkArray "++ cn ++ " Raw."++ rn 
                     ++ " M.Ix" ++ show dim ++ " " ++ element ++ " where\n"
                     ++ "  shapeFA  = to" ++ show dim ++ "d Raw.shape_" ++ sn ++ "\n"
                     ++ "  newFA    = from" ++ show dim ++ "d Raw.new_" ++ sn ++ "\n"
                     ++ "  valuesFA = Raw.values_" ++ sn ++ "\n"
          objectString = "\nnewtype " ++ cn ++ " c = " ++ cn ++ " (F.ForeignPtr Raw." ++ rn ++ ")\n"
                      ++ "instance FutharkObject " ++ cn ++ " Raw." ++ rn ++ " where\n"
                      ++ "  wrapFO = " ++ cn ++ "\n"
                      ++ "  freeFO = Raw.free_" ++ sn ++ "\n"
                      ++ "  withFO (" ++ cn ++ " fp) = F.withForeignPtr fp\n"

instanceDeclarations _ = ""

instanceDeclarationString headerItems = concatMap instanceDeclarations headerItems

haskellType' s = 
    let pn = length $ dropWhile (/='*') s
        ts = dropWhile (=="const") $ words $ takeWhile (/='*') s
     in if head ts == "struct" 
            then capitalize (drop 8 $ ts !! 1) ++ " c"
            else (case lookup (head ts) varTable of 
                    Just s -> s; 
                    Nothing -> error $ "type " ++ s ++ "not found";)

entryCall (Fun (_, n) args) 
    = if isEntry 
        then "\n" ++ typeDeclaration ++ input ++ preCall ++ call ++ postCall
        else ""
    where
        sn = drop 8 n
        isEntry = take 5 sn == "entry"
        en = drop 6 sn
        isFO a = case lookup (takeWhile (/='*') $ last $ words $ fst a) varTable 
                    of Just _ -> False; Nothing -> True; 
        (inArgs, outArgs) = partition ((=="in").take 2.snd) $ tail args
        typeDeclaration = en ++ "\n  :: " 
                       ++ concatMap (\i -> haskellType' (fst i) ++ "\n  -> " ) inArgs
                       ++ "FT c " ++ wrapIfNotOneWord (intercalate ", " $ map (\o -> haskellType' $ fst o) outArgs) ++ "\n"
        input = unwords (en : map snd inArgs) ++ "\n  =  FT.unsafeLiftFromIO $ \\context\n  -> "
        preCall = concat 
                $ map (\i -> "T.withFO " ++ snd i ++ " $ \\" ++ snd i ++ "'\n  -> ") (filter isFO inArgs)
               ++ map (\o -> "F.malloc >>= \\" ++ snd o ++ "\n  -> ") outArgs 
        call = "C.inContextWithError context (\\context'\n  -> Raw." ++ sn ++ " context' " 
            ++ unwords ((map snd $ outArgs) ++ (map (\i -> if isFO i then snd i ++ "'" else snd i) inArgs)) ++ ")\n  >> "
        peek o = if isFO o then "U.peekFreeWrapIn context " else "U.peekFree "
        postCall = (if length outArgs > 1
                        then  concatMap (\o -> peek o ++ snd o ++ " >>= \\" ++ snd o ++ "'\n  -> ") outArgs
                          ++ "return " ++ wrapIfNotOneWord (intercalate ", " $ map (\o -> snd o ++ "'") outArgs)
                        else peek (head outArgs) ++ snd (head outArgs))
                ++ "\n"

entryCall _ = ""
        
entryCallString headerItems = concatMap entryCall headerItems

data Import = N String | Q String String

globalImport (N m) = "import " ++ m ++ "\n"
globalImport (Q m a) = "import qualified " ++ m ++ " as " ++ a ++ "\n"
localImport moduleName (N sub) = globalImport $ N (moduleName ++ "." ++ sub)
localImport moduleName (Q sub a) = globalImport $ Q (moduleName ++ "." ++ sub) a

haskellHeader moduleName subModuleName exports extensions localImports globalImports
    =  (if length extensions > 0 
        then "{-# LANGUAGE " ++ intercalate ", " extensions ++ " #-}" 
        else "")
    ++ "\nmodule " 
    ++ moduleName ++ (case subModuleName of Nothing -> ""; Just n -> '.':n)
    ++ (if length exports > 0 then " (" ++ intercalate ", " exports ++ ")" else "")
    ++ " where\n"
    ++ concatMap (localImport moduleName) localImports
    ++ concatMap globalImport globalImports

writeModule directory moduleName subModuleName exports extensions localImports globalImports body 
    = writeFile fn string
    where fn = directory ++ "/" ++ moduleName ++ (case subModuleName of Just n -> "/" ++ n; Nothing -> "") ++ ".hs"
          string = haskellHeader moduleName subModuleName exports extensions localImports globalImports ++ body

main :: IO ()
main = do
    (backend: headerName: srcDir: moduleName: _) <- getArgs
    header <- readHeader headerName

    typeClassesBody <- readFile $ refDir ++ "/TypeClasses.hs"
    configBody      <- readFile $ refDir ++ "/Config." ++ backend ++ ".hs"
    contextBody     <- readFile $ refDir ++ "/Context.hs"
    fTBody          <- readFile $ refDir ++ "/FT.hs"
    utilsBody       <- readFile $ refDir ++ "/Utils.hs"
    
    createDirectoryIfMissing False (srcDir ++ "/" ++ moduleName)
    mapM_ (\(smn, exps, exts, lis, gis, body) -> writeModule srcDir moduleName smn exps exts lis gis body) 
        [ ( Just "Raw"
          , []
          , ["ForeignFunctionInterface"]
          , [] 
          , [ N "Data.Int (Int8, Int16, Int32, Int64)"
            , N "Data.Word (Word8, Word16, Word32, Word64)"
            , N "Foreign.C.Types (CBool(..), CSize(..), CChar(..))"
            , N "Foreign.Ptr (Ptr)" ] ++ specific backend
          , rawImportString header )
        , ( Just "TypeClasses"
          , [ "FutharkObject", "FutharkArray"
            , "freeFO", "withFO", "wrapFO", "newFA", "shapeFA", "valuesFA"
            , "Input", "Output"
            , "fromFuthark", "toFuthark"]
          , ["MultiParamTypeClasses", "FunctionalDependencies"]
          , [Q "Raw" "Raw", N "FT"] 
          , [N "Foreign", Q "Data.Massiv.Array" "M"]
          , typeClassesBody ) 
        , ( Just "Config"
          , []
          , []
          , [Q "Raw" "Raw"]
          , [ N "Foreign.C" ] ++ specific backend
          , configBody ) 
        , ( Just "Context"
          , []
          , []
          , [Q "Raw" "Raw", N "Config"]
          , [N "Foreign as F", Q "Foreign.Concurrent" "FC", N "Foreign.C" ]
          , contextBody )
        , ( Just "FT"
          , ["FT", "runFTIn", "runFTWith", "runFT", "unsafeLiftFromIO"]
          , ["RankNTypes", "ExistentialQuantification"]
          , [N "Context", N "Config"]
          , [N "System.IO.Unsafe"]
          , fTBody ) 
        , ( Just "Utils"
          , []
          , [ "RankNTypes"
            , "FlexibleInstances"
            , "MultiParamTypeClasses"
            , "UndecidableInstances"]
          , [Q "Raw" "Raw", N "Context", N "FT", N "TypeClasses"]
          , [ N "Foreign as F", Q "Foreign.Concurrent" "FC", N "Foreign.C"
            , Q "Data.Massiv.Array" "M", Q "Data.Massiv.Array.Unsafe" "MU"]
          , utilsBody )
        , ( Just "Types"
          , []
          , ["RankNTypes", "ExistentialQuantification"
            , "MultiParamTypeClasses", "TypeSynonymInstances", "FlexibleInstances"]
          , [Q "Raw" "Raw", N "Utils", N "TypeClasses"]
          , [ Q "Foreign" "F", Q "Data.Massiv.Array" "M"
            , N "Data.Int (Int8, Int16, Int32, Int64)"
            , N "Data.Word (Word8, Word16, Word32, Word64)"
            , N "Foreign.C.Types (CBool(..), CSize(..), CChar(..))"
            , N "Foreign.Ptr (Ptr)" ]
          , instanceDeclarationString header )
        , ( Just "Entries"
          , []
          , []
          , [ Q "Raw" "Raw", Q "Context" "C", N "FT (FT)", Q "FT" "FT"
            , Q "Utils" "U", N "Types", Q "TypeClasses" "T" ]
            , [ N "Data.Int (Int8, Int16, Int32, Int64)"
              , N "Data.Word (Word8, Word16, Word32, Word64)" 
              , Q "Foreign" "F", N "Foreign.C.Types" ]
          , entryCallString header ) 
        , ( Nothing
          , ["module F"]
          , []
          , [ Q "Context" "F"
            , Q "Config" "F hiding (setOption)"
            , Q "TypeClasses" "F hiding (FutharkObject, FutharkArray)"
            , Q "Utils" "F ()"
            , Q "FT" "F"]
          , []
          , "" ) ]
    where refDir = "code"
          specific backend = case backend of
             "opencl" -> [N "Control.Parallel.OpenCL (CLMem, CLCommandQueue)"]
