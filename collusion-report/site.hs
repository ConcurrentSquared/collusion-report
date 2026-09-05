{-# LANGUAGE OverloadedStrings #-}
import Control.Applicative ((<|>))
import Control.Monad (forM, unless)
import Data.Char (isAscii, isAlphaNum, ord)
import Data.List (inits, intercalate, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Time (UTCTime, defaultTimeLocale, parseTimeM)
import Hakyll hiding (chronological, escapeHtml)
import Numeric (showHex)
import System.Directory (doesDirectoryExist, makeAbsolute)
import System.Environment (getArgs, withArgs)
import System.FilePath ((</>), takeBaseName)

main :: IO ()
main = do
    args <- getArgs
    case args of
        folder : commands -> do
            source <- makeAbsolute "."
            input <- makeAbsolute folder
            exists <- doesDirectoryExist (input </> "texts")
            unless exists $ fail $ "No texts directory in " ++ input
            -- Remove our folder argument before Hakyll parses its own command.
            -- Rebuild by default so switching packs also removes old group pages.
            withArgs (if null commands then ["rebuild"] else commands) $
                compileWebsite source input
        _ -> fail "Usage: site DATA_FOLDER [build|rebuild|watch|clean]"

compileWebsite :: FilePath -> FilePath -> IO ()
compileWebsite source input = hakyllWith config $ do
    -- The selected pack is the provider, so Hakyll tracks the actual input files.
    groups <- buildTagsWith (\identifier -> do
        metadata <- getMetadata identifier
        pure [fromMaybe "Ungrouped" $ lookupString "group" metadata])
        "texts/*.md" groupIdentifier

    let members = tagsMap groups
        -- Index immediate children only; never flatten descendants onto a page.
        tree = Map.fromListWith Map.union
            [(parent, Map.singleton child ())
            | (name, _) <- members
            , prefix <- tail (inits (splitGroup name))
            , let parent = init prefix
            , let child = last prefix]
        children prefix = Map.keys $ Map.findWithDefault Map.empty prefix tree
        entry prefix child =
            let path = prefix ++ [child]
                identifier = if null (children path)
                    then groupIdentifier (intercalate "/" path)
                    else folderIdentifier path
            in Item identifier (child ++ if null (children path) then "" else "/")
        listing prefix = listField "groups" directoryContext $
            pure $ map (entry prefix) (children prefix)

    -- Templates belong to this project, not to the selected reading pack.
    rulesExtraDependencies [AlwaysOutOfDate] $ do
        mapM_ (\path -> create [fromFilePath path] $
            compile $ unsafeCompiler (readFile $ source </> path)
                >>= makeItem >>= compileTemplateItem >>= makeItem)
            ["templates/default.html", "templates/groups.html", "templates/group.html",
             "templates/fragment.html", "templates/directory.html"]

    match "texts/*.md" $ do
        route $ customRoute $ \identifier ->
            "fragments/" ++ takeBaseName (toFilePath identifier) ++ ".html"
        compile $ do
            body <- getResourceBody
            escaped <- saveSnapshot "body" $ fmap escapeHtml body
            name <- fromMaybe "Ungrouped" <$> getMetadataField (itemIdentifier body) "group"
            let context = constField "navigation" (breadcrumbs (init $ splitGroup name)
                            ++ " / " ++ link (groupIdentifier name) "Fragments")
                       <> fragmentContext
            loadAndApplyTemplate "templates/fragment.html" context escaped
                >>= loadAndApplyTemplate "templates/default.html" context
                >>= relativizeUrls

    tagsRules groups $ \name pattern -> do
        route idRoute
        compile $ do
            fragments <- chronological =<< loadAllSnapshots pattern "body"
            let context = constField "title" (escapeHtml name)
                       <> constField "navigation" (breadcrumbs (init $ splitGroup name))
                       <> constField "count" (show $ length fragments)
                       <> listField "fragments" fragmentContext (pure fragments)
                       <> defaultContext
            makeItem ""
                >>= loadAndApplyTemplate "templates/group.html" context
                >>= loadAndApplyTemplate "templates/default.html" context
                >>= relativizeUrls

    mapM_ (\prefix -> create [folderIdentifier prefix] $ do
        route idRoute
        compile $ do
            let name = intercalate "/" prefix
                -- A path can contain both its own records and child groups.
                own = [Item (groupIdentifier name) "Fragments in this group"
                      | name `elem` map fst members]
                context = constField "title" (escapeHtml name ++ "/")
                       <> constField "navigation" (breadcrumbs (init prefix))
                       <> listField "groups" directoryContext
                            (pure $ own ++ map (entry prefix) (children prefix))
                       <> defaultContext
            makeItem ""
                >>= loadAndApplyTemplate "templates/directory.html" context
                >>= loadAndApplyTemplate "templates/default.html" context
                >>= relativizeUrls)
        (filter (not . null) $ Map.keys tree)

    rulesExtraDependencies [AlwaysOutOfDate] $ create ["index.html"] $ do
        route idRoute
        compile $ do
            let context = listing []
                       <> constField "title" "OpenAI Collusion Archives"
                       <> defaultContext
            -- Keep the author's homepage, including its FAQ.
            homepage <- unsafeCompiler $ readFile (source </> "index.html")
            makeItem (dropFrontmatter homepage)
                >>= applyAsTemplate context
                >>= loadAndApplyTemplate "templates/default.html" context
                >>= relativizeUrls
  where
    config = defaultConfiguration
        { providerDirectory = input
        , destinationDirectory = source </> "_site"
        , storeDirectory = source </> "_cache"
        , tmpDirectory = source </> "_cache/tmp"
        }

-- Interpret slash-separated metadata as a hierarchy, but encode each segment
-- independently so punctuation, empty segments and dot paths stay distinct.
splitGroup :: String -> [String]
splitGroup value = case break (== '/') value of
    (part, []) -> [part]
    (part, _ : rest) -> part : splitGroup rest

encodeSegment :: String -> String
encodeSegment "" = "_empty_"
encodeSegment "." = "_2e_"
encodeSegment ".." = "_2e__2e_"
encodeSegment value = concatMap encode value
  where
    encode c | isAscii c && (isAlphaNum c || c `elem` ("-." :: String)) = [c]
             | otherwise = "_" ++ showHex (ord c) "_"

folderIdentifier :: [String] -> Identifier
folderIdentifier parts = fromFilePath $
    "groups/" ++ intercalate "/" (map encodeSegment parts) ++ "/index.html"

groupIdentifier :: String -> Identifier
groupIdentifier name = fromFilePath $
    "groups/" ++ intercalate "/" (map encodeSegment $ splitGroup name) ++ "/fragments.html"

directoryContext :: Context String
directoryContext = field "name" (pure . escapeHtml . itemBody) <> urlField "url"

link :: Identifier -> String -> String
link identifier label = "<a href=\"" ++ toUrl (toFilePath identifier)
    ++ "\">" ++ escapeHtml label ++ "</a>"

breadcrumbs :: [String] -> String
breadcrumbs parts = intercalate " / " $
    link "index.html" "All groups" :
    [link (folderIdentifier prefix) (last prefix) | prefix <- tail (inits parts)]

fragmentContext :: Context String
fragmentContext =
    field "anchor" (pure . takeBaseName . toFilePath . itemIdentifier)
    <> field "title" (\item -> do
        title <- getMetadataField (itemIdentifier item) "title"
        pure $ escapeHtml $ case title of
            Just value | not (null value) -> value
            _ -> "Untitled")
    <> field "date" (\item -> do
        date <- getMetadataField (itemIdentifier item) "timestamp"
        pure $ escapeHtml $ fromMaybe "Undated" date)
    <> field "author" (\item -> do
        author <- getMetadataField (itemIdentifier item) "author"
        pure $ escapeHtml $ fromMaybe "Unknown" author)
    <> field "source" (\item -> do
        source <- getMetadataField (itemIdentifier item) "source_url"
        pure $ escapeHtml $ fromMaybe "Unknown" source)
    <> urlField "url"
    <> bodyField "body"

chronological :: [Item String] -> Compiler [Item String]
chronological items = do
    dated <- forM items $ \item -> do
        timestamp <- getMetadataField (itemIdentifier item) "timestamp"
        date <- case timestamp of
            Nothing -> pure Nothing
            Just value -> case parseTimestamp value of
                Just parsed -> pure $ Just parsed
                Nothing -> fail $ "Invalid timestamp in " ++ show (itemIdentifier item) ++ ": " ++ value
        pure ((isNothing date, date, itemIdentifier item), item)
    pure $ map snd $ sortOn fst dated

parseTimestamp :: String -> Maybe UTCTime
parseTimestamp value =
    parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%Ez" value
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" value

escapeHtml :: String -> String
escapeHtml = concatMap escape
  where
    escape '&' = "&amp;"
    escape '<' = "&lt;"
    escape '>' = "&gt;"
    escape '"' = "&quot;"
    escape '\'' = "&#39;"
    escape c = [c]

dropFrontmatter :: String -> String
dropFrontmatter content = case lines content of
    "---" : rest -> unlines $ drop 1 $ dropWhile (/= "---") rest
    _ -> content
