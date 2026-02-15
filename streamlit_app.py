import streamlit as st
from snowflake.snowpark.context import get_active_session
import re

st.set_page_config(layout="wide", page_title="YouTube AI Manager")
st.title("📺 YouTube Channel Comment Manager")

session = get_active_session()

# -- 1. Session State Initialization --
if 'active_vid' not in st.session_state:
    st.session_state.active_vid = None

# -- 2. Sidebar: Channel & Video Selection --
with st.sidebar:
    st.header("Channel Explorer")
    target_id = st.text_input("Target Channel ID:", placeholder="UCxxxxxxxxxxxx")
    
    if st.button("🔄 Sync Video List"):
        if target_id:
            with st.spinner("Fetching channel videos..."):
                session.sql("DELETE FROM OTHER_CHANNEL_VIDEOS").collect()
                session.call("FETCH_CHANNEL_CONTENT", target_id)
            st.rerun()
        else:
            st.error("Please enter a Channel ID.")

    st.divider()

    # Dropdown to select a video from the indexed list
    try:
        video_list_df = session.table("OTHER_CHANNEL_VIDEOS").order_by("PUBLISHED_AT", ascending=False).to_pandas()
        if not video_list_df.empty:
            option = st.selectbox("Select a video:", video_list_df['TITLE'])
            selected_id = video_list_df[video_list_df['TITLE'] == option]['VIDEO_ID'].values[0]
            
            if st.button("🚀 Fetch & Analyze New Video"):
                st.session_state.active_vid = selected_id
                with st.spinner("Wiping old data and analyzing new comments..."):
                    # 1. Wipe the stage
                    session.sql("DELETE FROM YT_COMMENTS_STAGE").collect()
                    # 2. Fetch comments for this specific ID
                    session.call("FETCH_YOUTUBE_COMMENTS", selected_id)
                    # 3. AI Analysis
# Updated Analysis: Clean SQL-Safe Prompt
                instructions = (
            "SYSTEM: You are a fellow viewer. Tone: Casual. "
            "Constraint: Write ONLY the reply text. Max 2 sentences. "
            "User Comment: "
        )
                
                session.sql(f"""
                    UPDATE YT_COMMENTS_STAGE
                    SET SENTIMENT_LABEL = SNOWFLAKE.CORTEX.SENTIMENT(COMMENT_TEXT),
                        AI_DRAFT_REPLY = SNOWFLAKE.CORTEX.COMPLETE('llama3-8b', 
                            '{instructions}' || REPLACE(COMMENT_TEXT, CHAR(39), CHAR(39) || CHAR(39))
                        )
                    WHERE STATUS = 'PENDING_REVIEW'
                """).collect()
                st.rerun()
    except Exception as e:
        st.info("Sync the video list to get started.")

# --- 3. Main Display Area ---
if st.session_state.active_vid:
    st.subheader(f"Reviewing Video: {st.session_state.active_vid}")
    
    # Load comments
    df = session.sql("""
        SELECT COMMENT_ID, AUTHOR_NAME, COMMENT_TEXT, SENTIMENT_LABEL, AI_DRAFT_REPLY, STATUS 
        FROM YT_COMMENTS_STAGE 
        WHERE STATUS IN ('PENDING_REVIEW', 'APPROVED')
    """).to_pandas()

    if df.empty:
        st.success("All caught up! No pending comments.")
    else:
        # Loop through comments
        for index, row in df.iterrows():
            is_approved = (row['STATUS'] == 'APPROVED')
            
            with st.container(border=True):
                c1, c2 = st.columns([1, 2])
                with c1:
                    st.write(f"**{row['AUTHOR_NAME']}**")
                    st.caption(f"Sentiment: {row['SENTIMENT_LABEL']}")
                    st.write(row['COMMENT_TEXT'])
                with c2:
                    final_reply = st.text_area("Draft Reply:", value=row['AI_DRAFT_REPLY'], key=f"t_{row['COMMENT_ID']}")
                    
                    if not is_approved:
                        if st.button("✅ Approve", key=f"app_{row['COMMENT_ID']}"):
                            session.sql(f"""
                                UPDATE YT_COMMENTS_STAGE 
                                SET STATUS = 'APPROVED', 
                                    AI_DRAFT_REPLY = '{final_reply.replace("'", "''")}' 
                                WHERE COMMENT_ID = '{row['COMMENT_ID']}'
                            """).collect()
                            st.rerun()
                    else:
                        st.success("Ready to Post")

        st.divider()
        
        # Batch Posting Button
        approved_count = len(df[df['STATUS'] == 'APPROVED'])
        if approved_count > 0:
            if st.button(f"🚀 Push {approved_count} Replies to YouTube"):
                with st.spinner("Posting..."):
                    result = session.call("POST_YOUTUBE_REPLIES")
                    st.success(result)
                    st.rerun()
else:
    st.info("👈 Select a video from the sidebar to start.")
