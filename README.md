# Twilio Dialer Script

## Requirements

- Ruby
- Bundler
- Twilio account
- A `.csv` file containing contact information
## Setup

### 1. Clone the Repository

Clone the repository to your local machine:

```
git clone https://github.com/lchojnowski/dialer
cd dialer
```

### 2. Install Dependencies

Install the required gems using Bundler:

```
bundle install
```

### 3. Configure Environment Variables

Create a `.env` file in the root directory and add your Twilio credentials and other necessary configurations:

```env
TWILIO_ACCOUNT_SID=your_account_sid
TWILIO_AUTH_TOKEN=your_auth_token
TWILIO_PHONE_NUMBER=your_twilio_phone_number
CSV_FILE=path_to_your_csv_file.csv
INTRO_AUDIO=path_to_intro_audio.mp3
OUTRO_AUDIO=path_to_outro_audio.mp3
```

### 4. Prepare Your CSV File

Ensure your CSV file has the following structure (adjust column names if needed):

```csv
contact_id,telephone,recording_url,status
1,+1234567890,,
2,+1987654321,,
```
### 5. Running the Script
```
ruby dialer_script.rb
```
