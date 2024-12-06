require 'twilio-ruby'
require 'dotenv/load'
require 'csv'
require 'logger'

logger = Logger.new(STDOUT)
logger.level = Logger::DEBUG

account_sid = ENV['TWILIO_ACCOUNT_SID']
auth_token = ENV['TWILIO_AUTH_TOKEN']
twilio_number = ENV['TWILIO_PHONE_NUMBER']
csv_file = ENV['CSV_FILE']
intro_audio = ENV['INTRO_AUDIO']
outro_audio = ENV['OUTRO_AUDIO']

client = Twilio::REST::Client.new(account_sid, auth_token)
logger.info("🌟 Twilio client initialized with Account SID: #{account_sid}")

def update_csv(file, row_index, column, value, logger)
  table = CSV.table(file, converters: nil)
  table[row_index][column.to_sym] = value
  CSV.open(file, 'w', write_headers: true, headers: table.headers) do |csv|
    table.each { |row| csv << row }
  end
  logger.info("✅ Updated CSV at row #{row_index + 1}, column #{column} with value '#{value}'")
end

def with_retry(max_retries: 3, logger:, &block)
  retries = 0
  begin
    yield
  rescue Twilio::REST::TwilioError, StandardError => e
    retries += 1
    if retries < max_retries
      logger.warn("⚠️ Error occurred: #{e.message}. Retrying #{retries}/#{max_retries}...")
      retry
    else
      logger.error("❌ Failed after #{retries} retries: #{e.message}")
      raise e
    end
  end
end

def check_call_status(client, call_sid, logger, phone_number, timeout = 300)
  start_time = Time.now
  loop do
    sleep(8)
    call = client.calls(call_sid).fetch
    logger.info("📞 Call status for #{phone_number}: #{call.status}")

    if %w[completed busy failed no-answer rejected].include?(call.status)
      return call.status
    elsif Time.now - start_time > timeout
      logger.error("⏰ Timeout reached for call SID: #{call_sid} (Phone: #{phone_number})")
      return 'timeout'
    else
      logger.info("⏳ Call to #{phone_number} still in progress, status: #{call.status}...")
    end
  end
end

def check_recording_status(client, call_sid, contact_id, csv_file, index, logger, timeout = 300)
  start_time = Time.now
  loop do
    sleep(10)
    recordings = client.recordings.list(call_sid:)
    if recordings.any?
      recording = recordings.first
      recording_url = "https://api.twilio.com#{recording.uri.gsub('.json', '.mp3')}"
      logger.info("🎤 Recording URL for Contact ID #{contact_id}: #{recording_url}")
      update_csv(csv_file, index, 'recording_url', recording_url, logger)
      update_csv(csv_file, index, 'status', 'Completed', logger)
      return
    elsif Time.now - start_time > timeout
      logger.error("⏰ Timeout while fetching recording for call SID: #{call_sid}")
      update_csv(csv_file, index, 'status', 'Error: Timeout while fetching recording', logger)
      return
    else
      logger.info("⏳ No recording found yet for call SID: #{call_sid}, retrying...")
    end
  end
end

def process_calls(client, csv_file, twilio_number, intro_audio, outro_audio, logger)
  logger.info('🌱 Starting call processing...')
  table = CSV.table(csv_file, converters: nil)

  pending_calls = table.select { |row| row[:recording_url].nil? || row[:recording_url].strip.empty? }
  if pending_calls.empty?
    logger.info('🎉 No pending calls to process. Exiting.')
    return
  end

  threads = []

  table.each_with_index do |row, index|
    contact_id = row[:contact_id]
    phone_number = row[:telephone]
    recording_url = row[:recording_url]

    logger.info("📋 Processing contact ##{index + 1}: Contact ID: #{contact_id}, Phone Number: #{phone_number}")

    next unless recording_url.nil? || recording_url.strip.empty?

    if phone_number.nil? || phone_number.strip.empty?
      logger.error("❌ No phone number specified for Contact ID: #{contact_id}")
      update_csv(csv_file, index, 'status', 'Error: No Phone Number', logger)
      next
    end

    twiml = if phone_number.include?('W')
              phone_number, extension = phone_number.split('W', 2)
              logger.info("🎧 Detected DTMF. Dialing #{phone_number} and sending DTMF tones: #{extension}")
              "<Response><Pause length='1'/><Play>#{intro_audio}</Play><Pause length='1'/><Play>#{outro_audio}</Play><SendDigits>#{extension}</SendDigits></Response>"
            else
              logger.info("📞 Dialing phone number: #{phone_number}")
              "<Response><Pause length='1'/><Play>#{intro_audio}</Play><Pause length='1'/><Play>#{outro_audio}</Play></Response>"
            end

    threads << Thread.new do
      with_retry(logger:) do
        call = client.calls.create(
          from: twilio_number,
          to: phone_number,
          twiml:,
          record: true
        )
        logger.info("🚀 Call initiated to #{phone_number}, Call SID: #{call.sid}")
        update_csv(csv_file, index, 'status', 'Calling', logger)

        call_status = check_call_status(client, call.sid, logger, phone_number)

        case call_status
        when 'completed'
          logger.info("✅ Call completed for Contact ID: #{contact_id}")
          check_recording_status(client, call.sid, contact_id, csv_file, index, logger)
        else
          logger.error("❌ Call failed for Contact ID: #{contact_id}, Phone: #{phone_number}, Status: #{call_status}")
          update_csv(csv_file, index, 'status', "#{call_status}", logger)
        end
      end
    end
  end

  logger.info('⏳ Waiting for all threads to finish...')
  threads.each(&:join)
  logger.info('🎉 All threads have finished. Script is terminating.')
end

process_calls(client, csv_file, twilio_number, intro_audio, outro_audio, logger)
