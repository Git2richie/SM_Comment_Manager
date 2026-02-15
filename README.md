📺 YouTube AI Comment Manager
An intelligent, full-stack application built entirely within the Snowflake Data Cloud using Streamlit in Snowflake (SiS). This tool automates the process of fetching YouTube comments, analyzing sentiment, and drafting "fellow viewer" persona replies using Snowflake Cortex AI.

✨ Salient Features
- Serverless Architecture: No external web servers required. Hosted entirely on Snowflake.
- AI-Powered Drafting: Uses the llama3-8b model via Snowflake Cortex to generate casual, friendly, and human-like replies.
- Sentiment Analysis: Automatically labels comments as Positive, Negative, or Neutral to prioritize engagement.
- Persona-Driven: Custom prompt engineering ensures the AI doesn't sound like a "corporate bot," but rather a fellow member of the community.
- Secure API Integration: Utilizes Snowflake External Access and Secrets to securely communicate with the YouTube Data API.
- Dynamic Data Sync: One-click synchronization of channel video lists and video-specific comments.

🛠️ Tech Stack
- Frontend: Streamlit in Snowflake (Python)
- Backend & Storage: Snowflake Tables & Stored Procedures
- AI/ML: Snowflake Cortex AI (SENTIMENT, COMPLETE)
- Connectivity: Snowflake External Access (Integration with Google APIs)

🚀 Getting Started
1. Snowflake Setup
Ensure you have the following roles and privileges:
 -CREATE STREAMLIT on your schema.
 - CORTEX_USER database role for AI functions.

An External Access Integration configured for https://www.googleapis.com.

2. Database Schema
Create the following tables to store your metadata and stage your comments:

SQL

3. API Credentials
Store your YouTube Data API Key or OAuth Token in a Snowflake Secret:

SQL - RUN sql file from the repo
4. Deployment
Open Streamlit inside your Snowflake account.

Create a new app and paste the provided streamlit_app.py code.

Ensure the Python requirements include snowflake-snowpark-python.

📖 How to Use
- Sync Video List: Enter a YouTube Channel ID (Go to any channel you want to engage with and find its ID in it about section) and click "Sync." This pulls the latest video directory.
- Select & Process: Choose a video from the dropdown and click "Process This Video."
- Review AI Drafts: The app will fetch comments, analyze sentiment, and provide a "fellow viewer" draft reply.

Engage: Edit or approve the drafts to maintain your channel's community.

📈 Possible Next Steps
[ ] Context-Aware Analysis: Joining video descriptions and titles into the AI prompt for more relevant replies.
[ ] Analytics Dashboard: Visualizing comment sentiment trends over time.

🤝 Contributing
Contributions are welcome! Please feel free to submit a Pull Request or open an issue for any bugs or feature requests.# SM_Comment_Manager
