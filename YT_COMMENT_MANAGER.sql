--STEP-1 Create Integrations so that your application can talk to Youtube, you need to generate the token from Google Cloud console for YoutTube Data API 

CREATE OR REPLACE NETWORK RULE youtube_network_rule
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('oauth2.googleapis.com', 'www.googleapis.com');

CREATE OR REPLACE SECRET youtube_oauth_token
  TYPE = GENERIC_STRING
  SECRET_STRING = 'XXXXXXXXXXXXXXX';

-- Also store the Client ID and Secret for the refresh call
CREATE OR REPLACE SECRET youtube_client_id
  TYPE = GENERIC_STRING
  SECRET_STRING = 'XXXXXXXXXXXXXXXXXXXXXXXX';

CREATE OR REPLACE SECRET youtube_client_secret
  TYPE = GENERIC_STRING
  SECRET_STRING = 'XXXXXXXXXXXXXXXXX';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION youtube_api_integration
  ALLOWED_NETWORK_RULES = (youtube_network_rule)
  ALLOWED_AUTHENTICATION_SECRETS = (youtube_oauth_token, youtube_client_id, youtube_client_secret)
  ENABLED = TRUE;

--Step-2 Load the channel data (video ID Titles and timestamps) into a table and another table for comments 

CREATE OR REPLACE TABLE OTHER_CHANNEL_VIDEOS (
    VIDEO_ID STRING PRIMARY KEY,
    TITLE STRING,
    PUBLISHED_AT TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE YT_COMMENTS_STAGE (
    COMMENT_ID STRING PRIMARY KEY,
    VIDEO_ID STRING,
    AUTHOR_NAME STRING,
    COMMENT_TEXT STRING,
    SENTIMENT_LABEL STRING, -- We'll use Cortex to fill this
    AI_DRAFT_REPLY STRING,  -- We'll use Cortex to fill this
    STATUS STRING DEFAULT 'PENDING_REVIEW', -- PENDING_REVIEW, APPROVED, PUBLISHED
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- STEP-3 Procedures to fetch channel content this will populate the data in the tables we created in step-2

CREATE OR REPLACE PROCEDURE FETCH_CHANNEL_CONTENT(target_channel_id STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python', 'requests')
EXTERNAL_ACCESS_INTEGRATIONS = (youtube_api_integration)
SECRETS = ('cred_token' = youtube_oauth_token, 'cred_id' = youtube_client_id, 'cred_secret' = youtube_client_secret)
HANDLER = 'fetch_content'
AS
$$
import requests
import _snowflake

def fetch_content(session, target_channel_id):
    # Auth handshake to get access token
    client_id = _snowflake.get_generic_secret_string('cred_id')
    client_secret = _snowflake.get_generic_secret_string('cred_secret')
    refresh_token = _snowflake.get_generic_secret_string('cred_token')
    token_url = "https://oauth2.googleapis.com/token"
    token_resp = requests.post(token_url, data={"client_id": client_id, "client_secret": client_secret, "refresh_token": refresh_token, "grant_type": "refresh_token"}).json()
    access_token = token_resp['access_token']

    # Fetch last 20 videos from the target channel
    # Using 'search' endpoint filtered by channelId
    yt_url = f"https://www.googleapis.com/youtube/v3/search?part=snippet&channelId={target_channel_id}&maxResults=20&order=date&type=video"
    headers = {"Authorization": f"Bearer {access_token}"}
    
    resp = requests.get(yt_url, headers=headers).json()
    
    count = 0
    if 'items' in resp:
        for item in resp['items']:
            v_id = item['id']['videoId']
            title = item['snippet']['title']
            pub = item['snippet']['publishedAt']
            
            session.sql(f"""
                MERGE INTO OTHER_CHANNEL_VIDEOS AS target
                USING (SELECT '{v_id}' as id, '{title.replace("'","''")}' as t, '{pub}' as p) AS src
                ON target.VIDEO_ID = src.id
                WHEN NOT MATCHED THEN INSERT (VIDEO_ID, TITLE, PUBLISHED_AT) VALUES (src.id, src.t, src.p)
            """).collect()
            count += 1
        return f"Found and indexed {count} videos."
    return "Error or no videos found: " + str(resp)
$$;

-- PYTHON function to fetch comments
CREATE OR REPLACE PROCEDURE FETCH_YOUTUBE_COMMENTS(video_id STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python', 'requests')
EXTERNAL_ACCESS_INTEGRATIONS = (youtube_api_integration)
SECRETS = ('cred_token' = youtube_oauth_token, 'cred_id' = youtube_client_id, 'cred_secret' = youtube_client_secret)
HANDLER = 'fetch_comments'
AS
$$
import requests
import _snowflake

def fetch_comments(session, video_id):
    # 1. Refresh the Access Token
    client_id = _snowflake.get_generic_secret_string('cred_id')
    client_secret = _snowflake.get_generic_secret_string('cred_secret')
    refresh_token = _snowflake.get_generic_secret_string('cred_token')
    
    token_url = "https://oauth2.googleapis.com/token"
    data = {
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token"
    }
    
    token_resp = requests.post(token_url, data=data).json()
    access_token = token_resp['access_token']
    
    # 2. Call YouTube API for comments
    yt_url = f"https://www.googleapis.com/youtube/v3/commentThreads?part=snippet&videoId={video_id}&maxResults=10"
    headers = {"Authorization": f"Bearer {access_token}"}
    
    response = requests.get(yt_url, headers=headers).json()
    
    # 3. Insert into Table
    count = 0
    if 'items' in response:
        for item in response['items']:
            snippet = item['snippet']['topLevelComment']['snippet']
            c_id = item['id']
            author = snippet['authorDisplayName']
            text = snippet['textOriginal']
            
            # Simple merge to avoid duplicates
            session.sql(f"""
                MERGE INTO YT_COMMENTS_STAGE AS target
                USING (SELECT '{c_id}' as cid, '{video_id}' as vid, '{author.replace("'","''")}' as auth, '{text.replace("'","''")}' as txt) AS source
                ON target.COMMENT_ID = source.cid
                WHEN NOT MATCHED THEN INSERT (COMMENT_ID, VIDEO_ID, AUTHOR_NAME, COMMENT_TEXT) 
                VALUES (source.cid, source.vid, source.auth, source.txt)
            """).collect()
            count += 1
            
    return f"Successfully fetched {count} comments for video {video_id}"
$$;

  --Step-4 Update the comments table with the draft replies generated via Cortex functions

UPDATE YT_COMMENTS_STAGE
SET 
    -- 1. Get a Sentiment Label
    SENTIMENT_LABEL = SNOWFLAKE.CORTEX.SENTIMENT(COMMENT_TEXT),
    
    -- 2. Generate a Draft Reply
    AI_DRAFT_REPLY = SNOWFLAKE.CORTEX.COMPLETE(
        'mistral-large', -- A powerful model for creative writing
        CONCAT(
            'You are a friendly YouTube creator. Write a short, engaging reply to this comment: "', 
            COMMENT_TEXT, 
            '". Keep it under 2 sentences and sound natural.'
        )
    )
WHERE STATUS = 'PENDING_REVIEW';

-- Step-4 Procedure for posting Youtube replies
  
CREATE OR REPLACE PROCEDURE POST_YOUTUBE_REPLIES()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python', 'requests')
EXTERNAL_ACCESS_INTEGRATIONS = (youtube_api_integration)
SECRETS = ('cred_token' = youtube_oauth_token, 'cred_id' = youtube_client_id, 'cred_secret' = youtube_client_secret)
HANDLER = 'post_replies'
AS
$$
import requests
import _snowflake

def post_replies(session,):
    # 1. Get the Fresh Access Token
    client_id = _snowflake.get_generic_secret_string('cred_id')
    client_secret = _snowflake.get_generic_secret_string('cred_secret')
    refresh_token = _snowflake.get_generic_secret_string('cred_token')
    
    token_url = "https://oauth2.googleapis.com/token"
    data = {"client_id": client_id, "client_secret": client_secret, "refresh_token": refresh_token, "grant_type": "refresh_token"}
    token_resp = requests.post(token_url, data=data).json()
    access_token = token_resp['access_token']

    # 2. Find Approved Comments
    approved_comments = session.sql("SELECT COMMENT_ID, AI_DRAFT_REPLY FROM YT_COMMENTS_STAGE WHERE STATUS = 'APPROVED'").collect()
    
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json"
    }
    
    count = 0
    for row in approved_comments:
        parent_id = row['COMMENT_ID']
        reply_text = row['AI_DRAFT_REPLY']
        
        # YouTube API endpoint for replying to a comment thread
        yt_url = "https://www.googleapis.com/youtube/v3/comments?part=snippet"
        payload = {
            "snippet": {
                "parentId": parent_id,
                "textOriginal": reply_text
            }
        }
        
        resp = requests.post(yt_url, headers=headers, json=payload)
        
        if resp.status_code == 200:
            session.sql(f"UPDATE YT_COMMENTS_STAGE SET STATUS = 'PUBLISHED' WHERE COMMENT_ID = '{parent_id}'").collect()
            count += 1
            
    return f"Successfully posted {count} replies to YouTube!"
$$;
