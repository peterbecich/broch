{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving #-}
module Broch.Scotty where

import           Blaze.ByteString.Builder (toLazyByteString)
import           Control.Concurrent.STM
import           Control.Monad.Reader
import qualified Crypto.BCrypt as BCrypt
import qualified Crypto.PubKey.RSA as RSA
import           Data.Aeson hiding (json)
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import           Data.Int (Int64)
import           Data.List (intersect)
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as Map
import           Data.Maybe (fromJust)
import           Data.String (fromString)
import           Data.Text.Lazy (Text)
import qualified Data.Text.Lazy as L
import qualified Data.Text as T
import           Data.Text.Read (decimal)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy.Encoding as LE
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.UUID (toString)
import           Data.UUID.V4
import           Database.Persist.Sql (ConnectionPool, runMigrationSilent, runSqlPersistMPool)
import           Jose.Jwk
import           Jose.Jwa
import           Network.HTTP.Types
import qualified Network.Wai as W
import qualified Text.Blaze.Html5 as H
import           Text.Blaze.Html5.Attributes hiding (scope)
import           Text.Blaze.Html.Renderer.Text (renderHtml)
import qualified Web.ClientSession as CS
import           Web.Cookie
import           Web.Scotty.Trans

import           Broch.Model
import           Broch.OAuth2.Authorize
import           Broch.OAuth2.Token
import           Broch.OpenID.Discovery (defaultOpenIDConfiguration)
import           Broch.OpenID.IdToken
import           Broch.OpenID.Registration
import           Broch.OpenID.UserInfo
import qualified Broch.Persist as BP
import           Broch.Random
import           Broch.Token
import           Broch.Scim (ScimUser(..), Meta(..), createScimUser)

testClients :: [Client]
testClients =
    [ Client "admin" (Just "adminsecret") [ClientCredentials]                []                            300 300 [] True
    , Client "cf"    Nothing              [ResourceOwner]                    ["http://cf.com"]             300 300 [] True
    , Client "app"   (Just "appsecret")   [AuthorizationCode, RefreshToken]  ["http://localhost:8080/app"] 300 300 [CustomScope "scope1", CustomScope "scope2"] False
    ]

testUsers :: [ScimUser]
testUsers =
    [ (createScimUser Nothing "cat") { scimPassword = Just "cat" }
    , (createScimUser Nothing "dog") { scimPassword = Just "dog" }
    ]

newtype BrochState = BrochState { issuerUrl :: T.Text}

newtype BrochM a = BrochM { runBrochM :: ReaderT (TVar BrochState) IO a }
                     deriving (Functor, Monad, MonadIO, MonadReader (TVar BrochState))

brochM :: MonadTrans t => BrochM a -> t BrochM a
brochM = lift

gets :: (BrochState -> b) -> BrochM b
gets f = ask >>= liftIO . readTVarIO >>= return . f

modify :: (BrochState -> BrochState) -> BrochM ()
modify f = ask >>= liftIO . atomically . flip modifyTVar' f


data Except = WWWAuthenticate Text
            | InvalidToken Text
            | InsufficientScope [Scope]
--            | Forbidden
            | StringEx String
              deriving (Show, Eq)

instance ScottyError Except where
    stringError = StringEx
    showError   = fromString . show

handleEx :: Monad m => Except -> ActionT Except m ()
handleEx (WWWAuthenticate hdr) = status unauthorized401 >> setHeader "WWW-Authenticate" hdr
handleEx (InvalidToken msg)    = do
    status unauthorized401
    setHeader "WWW-Authenticate" $ L.concat ["Bearer, error=\"invalid_token\", error_description=\"", msg, "\""]
handleEx (InsufficientScope s) = do
    status forbidden403
    setHeader "WWW-Authenticate" $ L.concat ["Bearer, error=\"insufficient_scope\", scope=\"", L.fromStrict $ formatScope s, "\""]
handleEx _ = status internalServerError500 >> text "Whoops! Something went wrong!"

testBroch :: T.Text -> ConnectionPool -> IO W.Application
testBroch issuer pool = do
    _ <- runSqlPersistMPool (runMigrationSilent BP.migrateAll) pool
    mapM_ (\c -> runSqlPersistMPool (BP.createClient c) pool) testClients
    -- Create everything we need for the oauth endpoints
    -- First we need an RSA key for signing tokens
    let runDB = flip runSqlPersistMPool pool
    let getClient = liftIO . runDB . BP.getClientById
    let createAuthorization code uid clnt now scp n uri = liftIO $ runDB $
                            BP.createAuthorization code uid clnt now scp n uri

    let getAuthorization = liftIO . runDB . BP.getAuthorizationByCode
    let authenticateResourceOwner username password = do
            u <- liftIO . runDB $ BP.getUserByUsername username
            case u of
                Nothing          -> return Nothing
                Just (uid, hash) -> if BCrypt.validatePassword (TE.encodeUtf8 hash) (TE.encodeUtf8 password)
                                        then return $ Just uid
                                        else return Nothing

    let saveApproval a = runDB $ BP.createApproval a
    (kPub, kPr) <- withCPRG $ \g -> RSA.generate g 64 65537
    let createAccessToken = createJwtAccessToken $ RSA.private_pub kPr
    let decodeRefreshToken _ jwt = return $ decodeJwtRefreshToken kPr (TE.encodeUtf8 jwt)
    let getApproval uid clnt now = runDB $ BP.getApproval uid (clientId clnt) now
    let keySet = JwkSet [RsaPublicJwk kPub (Just "brochkey") Nothing Nothing]
    let config = toJSON $ defaultOpenIDConfiguration issuer
    let registerClient :: ClientMetaData -> IO Client
        registerClient c = do
            cid <- liftIO generateCode
            sec <- liftIO generateCode
            let client = makeClient (TE.decodeUtf8 cid) (TE.decodeUtf8 sec) c
            runDB $ BP.createClient $ client
            return client

        createIdToken uid client nons now code aToken = return $ createIdTokenJws RS256 kPr issuer (clientId client) nons uid now code aToken

        hashPassword p = do
            hash <- liftIO $ BCrypt.hashPasswordUsingPolicy BCrypt.fastBcryptHashingPolicy (TE.encodeUtf8 p)
            maybe (error "Hash failed") (return . TE.decodeUtf8) hash

        createUser scimData = do
            now <- fmap Just $ liftIO getCurrentTime
            uid <- fmap (T.pack . toString) $ liftIO $ nextRandom
            password <- hashPassword =<< (maybe randomPassword return $ scimPassword scimData)
            let meta = Meta now now Nothing Nothing
            runDB $ BP.createUser uid password scimData { scimId = Just uid, scimMeta = Just meta }

        getUser = liftIO . runDB . BP.getUserById

        userInfoHandler = withBearerToken (decodeJwtAccessToken kPr) [OpenID] $ \g -> do
            debug $ g
            scimUser <- getUser $ fromJust $ granterId g
            debug scimUser
            -- Convert from SCIM... yuk
            -- Todo: Filter data based on scope
            json $ scimUserToUserInfo $ fromJust scimUser


    mapM_ createUser testUsers

    -- Create the cookie encryption key
    -- TODO: abstract session data access
    csKey <- CS.getDefaultKey

    sync <- newTVarIO $ BrochState { issuerUrl = issuer }

    let runM m = runReaderT (runBrochM m) sync
        runActionToIO = runM

    scottyAppT runM runActionToIO $ do

        defaultHandler handleEx

        get "/" $ redirectFull "/home"

        get "/home" $ text "Hello, I'm the home page."

        get "/oauth/authorize" $ authorizationHandler csKey getClient createAuthorization getApproval createAccessToken createIdToken
        post "/oauth/token" $ tokenHandler getClient getAuthorization authenticateResourceOwner createAccessToken createIdToken decodeRefreshToken
        get "/login" $ do
            html $ renderHtml $ loginPage

        post "/login" $ do
            uid  <- param "username"
            pwd  <- param "password"
            user <- liftIO $ authenticateResourceOwner uid pwd

            case user of
                Nothing -> redirectFull "/login"
                Just u  -> do
                    setEncryptedCookie csKey "bsid" (TE.encodeUtf8 u)
                    l <- getCachedLocation csKey "/home"
                    redirectFull $ L.toStrict l

        get "/approval" $ do
            _      <- getAuthId csKey
            now    <- liftIO getPOSIXTime
            Just client <- param "client_id" >>= getClient
            scope  <- param "scope" >>= return . (L.splitOn " ")
            html $ renderHtml $ approvalPage client scope (round now)

        post "/approval" $ do
            user   <- getAuthId csKey
            clntId <- param "client_id"
            expiryTxt <- param "expiry"
            scope     <- param "scope"
            let Right (expiry, _) = decimal expiryTxt
                approval = Approval user clntId (map scopeFromName scope) (TokenTime $ fromIntegral (expiry :: Int64))
            liftIO $ saveApproval approval
            l <- getCachedLocation csKey "/uhoh"
            clearCachedLocation
            -- Redirect to authorization doesn't seem to work with oictests
            redirectFull $ L.toStrict l

        get  "/connect/userinfo" $ userInfoHandler
        post "/connect/userinfo" $ userInfoHandler

        post "/connect/register" $ do
            b <- body
            case eitherDecode b of
                Left err -> status badRequest400 >> text (L.pack err)
                Right v@(Object o) -> do
                    case fromJSON v of
                        Error e    -> status badRequest400 >> text (L.pack e)
                        Success md -> do
                            c <- liftIO $ registerClient md
                            -- Cheat here. Add the extra fields to the
                            -- original JSON object
                            json . Object $ HM.union o $ HM.fromList [("client_id", String $ clientId c), ("client_secret", String . fromJust $ clientSecret c), ("registration_access_token", String "this_is_a_worthless_fake"), ("registration_client_uri", String $ T.concat [issuer, "/client/", clientId c])]
                Right _            -> status badRequest400 >> text "Registration data must be a JSON Object"
        get "/logout" $ logout

        get "/.well-known/openid-configuration" $ json $ toJSON config

        get "/.well-known/jwks" $ json $ toJSON $ keySet

        -- SCIM API

        post   "/Users" $ do
            -- parse JSON request to SCIM user
            -- store user
            -- create meta and etag
            -- re-read user and return
            b <- body
            case eitherDecode b of
                Left err -> status badRequest400 >> text (L.pack err)
                Right scimUser -> do
                    -- TODO: Check data, username etc
                    liftIO $ createUser scimUser

        get    "/Users/:uid" undefined
        put    "/Users/:uid" undefined
        patch  "/Users/:uid" $ status notImplemented501
        delete "/Users/:uid" undefined
        post   "/Groups" undefined
        get    "/Groups/:uid" undefined
        put    "/Groups/:uid" undefined
        patch  "/Groups/:uid" undefined
        delete "/Groups/:uid" undefined

  where
    randomPassword = fmap (TE.decodeUtf8 . B64.encode) $ randomBytes 12


    redirectFull :: T.Text -> ActionT Except BrochM b
    redirectFull u = do
        baseUrl <- brochM $ gets issuerUrl
        let url = L.fromStrict $ T.concat [baseUrl, u]
        liftIO $ putStrLn $ "Redirecting to: " ++ show url
        redirect url

    authorizationHandler csKey getClient createAuthorization getApproval createAccessToken createIdToken = do
        -- request >>= debug . W.rawQueryString

        user <- getAuthId csKey
        env  <- fmap toMap params
        now  <- liftIO getPOSIXTime

        response <- processAuthorizationRequest getClient (liftIO generateCode) createAuthorization resourceOwnerApproval createAccessToken createIdToken user env now
        case response of
            Left e    -> evilClientError e
            Right url -> redirect $ L.fromStrict url

      where
        evilClientError err = status badRequest400 >> text (L.pack $ show err)

        fakeApproval _ _ requestedScope _ = return requestedScope

        resourceOwnerApproval uid client requestedScope now = do
            -- Try to load a previous approval
            maybeApproval <- liftIO $ getApproval uid client now
            case maybeApproval of
                -- TODO: Check scope overlap and allow asking for extra scope
                -- not previously granted
                Just (Approval _ _ scope _) -> return $ scope `intersect` requestedScope
                -- Nothing exists: Redirect to approval handler with scopes and client id
                Nothing -> do
                    let query = renderSimpleQuery True [("client_id", TE.encodeUtf8 $ clientId client), ("scope", TE.encodeUtf8 $ formatScope requestedScope)]
                    cacheLocation csKey
                    redirectFull $ TE.decodeUtf8 $ B.concat ["/approval", query]

    tokenHandler getClient getAuthorization authenticateResourceOwner createAccessToken createIdToken decodeRefreshToken = do
        client <- basicAuthClient getClient
        case client of
            Left (st, err) -> status st >> text err
            Right c        -> do
                env  <- fmap toMap params
                now  <- liftIO getPOSIXTime
                resp <- processTokenRequest env c now getAuthorization authenticateResourceOwner createAccessToken createIdToken decodeRefreshToken
                case resp of
                    Left bad -> status badRequest400 >> json (toJSON bad)
                    Right tr -> json $ toJSON tr

    getAuthId key = do
        uid <- getEncryptedCookie key "bsid"
        case uid of
            Just u  -> return (TE.decodeUtf8 u)
            Nothing -> cacheLocation key >> redirectFull "/login"

formatScope :: [Scope] -> T.Text
formatScope s = T.intercalate " " (map scopeName s)

debug :: (MonadIO m, Show a) => a -> m ()
debug = liftIO . putStrLn . show

loginPage :: H.Html
loginPage = H.html $ do
    H.head $ do
      H.title "Login."
    H.body $ do
        H.form H.! method "post" H.! action "/login" $ do
            H.input H.! type_ "text" H.! name "username"
            H.input H.! type_ "password" H.! name "password"
            H.input H.! type_ "submit" H.! value "Login"

approvalPage :: Client -> [Text] -> Int64 -> H.Html
approvalPage client scopes now = H.docTypeHtml $ H.html $ do
    H.head $ do
      H.title "Approvals"
    H.body $ do
        H.h2 $ "Authorization Approval Request"
        H.form H.! method "post" H.! action "/approval" $ do
            H.input H.! type_ "hidden" H.! name "client_id" H.! value (H.toValue (clientId client))
            H.label H.! for "expiry" $ "Expires after"
            H.select H.! name "expiry" $ do
                H.option H.! value (H.toValue oneDay) H.! selected "" $ "One day"
                H.option H.! value (H.toValue oneWeek) $ "One week"
                H.option H.! value (H.toValue oneMonth) $ "30 days"
            forM_ scopes $ \s -> do
                H.input H.! type_ "checkBox" H.! name "scope" H.! value (H.toValue s) H.! checked ""
                H.toHtml s
                H.br

            H.input H.! type_ "submit" H.! value "Approve"
  where
    aDay    = round posixDayLength :: Int64
    oneDay  = now + aDay
    oneWeek = now + 7*aDay
    oneMonth = now + 30*aDay


logout :: ActionT Except BrochM ()
logout = clearCookie "bsid"

clearCachedLocation :: ActionT Except BrochM ()
clearCachedLocation = clearCookie "loc"

cacheLocation :: CS.Key -> ActionT Except BrochM ()
cacheLocation key = do
    r <- request
    setEncryptedCookie key "loc" $ B.concat [W.rawPathInfo r, W.rawQueryString r]

getCachedLocation :: CS.Key -> L.Text -> ActionT Except BrochM L.Text
getCachedLocation key defaultUrl = getEncryptedCookie key "loc" >>=
                                      return . (maybe defaultUrl (L.fromStrict . TE.decodeUtf8))


makeCookie :: B.ByteString -> B.ByteString -> SetCookie
makeCookie n v = def { setCookieName = n, setCookieValue = v, setCookieHttpOnly = True, setCookiePath = Just "/" }

renderSetCookie' :: SetCookie -> Text
renderSetCookie' = LE.decodeUtf8 . toLazyByteString . renderSetCookie

getEncryptedCookie :: CS.Key -> B.ByteString -> ActionT Except BrochM (Maybe B.ByteString)
getEncryptedCookie key n = getCookie n >>= return . join .fmap (CS.decrypt key)

setEncryptedCookie :: CS.Key -> B.ByteString -> B.ByteString -> ActionT Except BrochM ()
setEncryptedCookie key n v = do
    v' <- liftIO $ CS.encryptIO key v
    setCookie n v'

setCookie :: B.ByteString -> B.ByteString -> ActionT Except BrochM ()
setCookie n v = setHeader "Set-Cookie" $ renderSetCookie' $ makeCookie n v

clearCookie :: B.ByteString -> ActionT Except BrochM ()
clearCookie n = setHeader "Set-Cookie" $ renderSetCookie' $ (makeCookie n "") { setCookieMaxAge = Just 0 }

getCookie :: B.ByteString -> ActionT Except BrochM (Maybe B.ByteString)
getCookie n = do
    cookies <- fmap (fmap (parseCookies . BL.toStrict . LE.encodeUtf8)) $ header "Cookie"
    case cookies of
        Nothing -> return Nothing
        Just cs -> return $ lookup n cs

toMap :: [(Text, Text)] -> Map.Map T.Text [T.Text]
toMap = Map.unionsWith (++) . map (\(x, y) -> Map.singleton (L.toStrict x) [(L.toStrict y)])

withBearerToken :: MonadIO m
                => (B.ByteString -> Maybe AccessGrant)
                -> [Scope]
                -> (AccessGrant
                -> ActionT Except m ())
                -> ActionT Except m ()
withBearerToken decodeToken requiredScope f = withAuthorizationHeader wwwAuthHeader $ \h -> do
    case bearerToken h of
        Nothing -> unauthorized
        Just t  -> case decodeToken t of
            Just g@(AccessGrant _ _ _ scp (TokenTime ex)) -> do
                -- Check expiry and scope
                now <- liftIO getPOSIXTime
                unless (ex > now) $ raise $ InvalidToken "Token has expired"
                unless (requiredScope `intersect` scp == requiredScope) $ raise $ InsufficientScope requiredScope
                f g

            Nothing -> unauthorized
  where
    unauthorized = status unauthorized401 >> setHeader "WWW-Authenticate" wwwAuthHeader
    wwwAuthHeader = "Bearer"
    bearerToken h = case B.split ' ' h of
                       ["Bearer", t] -> Just t
                       _             -> Nothing


basicAuthClient :: (ScottyError e, Monad m)
                => (T.Text -> ActionT e m (Maybe Client))
                -> ActionT e m (Either (Status, L.Text) Client)
basicAuthClient getClient = do
    r <- request
    case basicAuthCredentials r of
        Left  msg           -> return $ Left (unauthorized401, msg)
        Right (cid, secret) -> do
            client <- getClient cid
            return $ maybe (Left (forbidden403, "Authentication failed")) Right $ client >>= validateSecret secret

-- TODO: Use hashed secrets
validateSecret :: T.Text -> Client -> Maybe Client
validateSecret secret client = clientSecret client >>= \s ->
                                  if secret == s
                                  then Just client
                                  else Nothing

-- | Extract the Basic authentication credentials from a WAI request.
-- Returns an error message if the header is missing or cannot be decoded.
basicAuthCredentials :: W.Request -> Either Text (T.Text, T.Text)
basicAuthCredentials r = do
    authzHdr <- maybe (Left "Authentication required") return $ lookup hAuthorization $ W.requestHeaders r
    maybe (Left "Invalid authorization header") return $ decodeHeader authzHdr
  where
    decodeHeader h = case B.split ' ' h of
                       ["Basic", b] -> either (const Nothing) creds $ B64.decode b
                       _            -> Nothing
    creds bs = case fmap (T.break (== ':')) $ TE.decodeUtf8' bs of
                 Left _       -> Nothing
                 Right (u, p) -> if T.length p == 0
                                 then Nothing
                                 else Just (u, T.tail p)


withAuthorizationHeader :: (ScottyError e, Monad m)
                        => L.Text
                        -> (B.ByteString -> ActionT e m ())
                        -> ActionT e m ()
withAuthorizationHeader authResponseHdr f = do
    r <- request
    let h = lookup hAuthorization $ W.requestHeaders r
    case h of Nothing -> status unauthorized401 >> setHeader "WWW-Authenticate" authResponseHdr
              Just a  -> f a


