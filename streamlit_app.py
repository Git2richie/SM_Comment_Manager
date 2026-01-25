import streamlit as st
from snowflake.snowpark.context import get_active_session
import re

st.set_page_config(layout="wide")
st.title("📺 YouTube AI Comment Manager")

session = get_active_session()

# --- NEW: Fetching Section ---
with st.sidebar:
    st.header("Import New Comments")
    url_input = st.text_input("Paste YouTube Video URL:", placeholder="https://www.youtube.com/watch?v=...")
    
    if st.button("📥 Fetch & Analyze"):
        if url_input:
            # Extract Video ID using Regex
            video_id_match = re.search(r"(?:v=|\/)([0-9A-Za-z_-]{11}).*", url_input)
            if video_id_match:
                vid_id = video_id_match.group(1)
                with st.spinner(f"Fetching comments for {vid_id}..."):
                    session.sql("DELETE FROM YT_COMMENTS_STAGE").collect()   
                   
                    # 1. Call the Fetch Procedure
                    session.call("FETCH_YOUTUBE_COMMENTS", vid_id)
                    
                    # 2. Run the AI Analysis immediately
                    session.sql("""
                        UPDATE YT_COMMENTS_STAGE
                        SET 
                            SENTIMENT_LABEL = SNOWFLAKE.CORTEX.SENTIMENT(COMMENT_TEXT),
                            AI_DRAFT_REPLY = SNOWFLAKE.CORTEX.COMPLETE(
                                'mistral-large',
                                CONCAT('You are a friendly creator. Reply to: "', COMMENT_TEXT, '"')
                            )
                        WHERE STATUS = 'PENDING_REVIEW' AND VIDEO_ID = ?
                    """, params=[vid_id]).collect()
                    
                st.success("Fetched and Analyzed!")
                st.rerun()
            else:
                st.error("Invalid YouTube URL. Please check it.")
        else:
            st.warning("Please paste a URL first.")

# --- Existing Review Section ---
st.subheader("Pending Approvals")
def load_data():
    return session.sql("SELECT COMMENT_ID, AUTHOR_NAME, COMMENT_TEXT, AI_DRAFT_REPLY FROM YT_COMMENTS_STAGE WHERE STATUS = 'PENDING_REVIEW'").to_pandas()

df = load_data()
# # ... (rest of your loop logic for displaying comments)

# # Load comments that need review
# def load_data():
#     return session.sql("SELECT COMMENT_ID, AUTHOR_NAME, COMMENT_TEXT, AI_DRAFT_REPLY FROM YT_COMMENTS_STAGE WHERE STATUS = 'PENDING_REVIEW'").to_pandas()

# df = load_data()

if df.empty:
    st.success("No comments pending review! Great job.")
    if st.button("Refresh"):
        st.rerun()
else:
    for index, row in df.iterrows():
        with st.container(border=True):
            col1, col2 = st.columns([1, 2])
            
            with col1:
                st.subheader(row['AUTHOR_NAME'])
                st.write(f"**Comment:** {row['COMMENT_TEXT']}")
            
            with col2:
                # This allows you to modify the AI's draft
                final_reply = st.text_area("AI Suggested Reply (Edit if needed):", 
                                          value=row['AI_DRAFT_REPLY'], 
                                          key=f"text_{row['COMMENT_ID']}")
                
                if st.button("Approve & Post", key=f"btn_{row['COMMENT_ID']}"):
                    # Update status and save the final text
                    session.sql(f"""
                        UPDATE YT_COMMENTS_STAGE 
                        SET STATUS = 'APPROVED', 
                            AI_DRAFT_REPLY = '{final_reply.replace("'", "''")}'
                        WHERE COMMENT_ID = '{row['COMMENT_ID']}'
                    """).collect()
                    st.success("Comment marked for posting!")
                    st.rerun()

st.divider()
st.caption("Once approved, the status changes to 'APPROVED'. Next, we will build the script that actually sends these to YouTube.")
if st.button("🚀 Push Approved Replies to YouTube"):
    with st.spinner("Posting to YouTube..."):
        result = session.call("POST_YOUTUBE_REPLIES")
        st.success(result)
