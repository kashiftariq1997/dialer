require 'twilio-ruby'
require 'dotenv/load'
require 'csv'
require 'logger'
require 'byebug'

logger = Logger.new(STDOUT)
logger.level = Logger::DEBUG

account_sid = ENV['TWILIO_ACCOUNT_SID']
auth_token = ENV['TWILIO_AUTH_TOKEN']
twilio_number = ENV['TWILIO_PHONE_NUMBER']
csv_file = ENV['CSV_FILE']
intro_audio = ENV['INTRO_AUDIO']
outro_audio = ENV['OUTRO_AUDIO']

client = Twilio::REST::Client.new(account_sid, auth_token)
logger.info("Twilio client initialized with Account SID: #{account_sid}")

def update_csv(file, row_index, column, value, logger)
  table = CSV.table(file, converters: nil)
  table[row_index][column.to_sym] = value
  CSV.open(file, 'w', write_headers: true, headers: table.headers) do |csv|
    table.each { |row| csv << row }
  end
  logger.info("Updated CSV at row #{row_index}, column #{column} with value #{value}")
end

def with_retry(max_retries: 3, logger:, &block)
  retries = 0
  begin
    yield
  rescue Twilio::REST::TwilioError => e
    retries += 1
    if retries < max_retries
      logger.warn("Twilio error occurred. Retrying #{retries}/#{max_retries}: #{e.message}")
      retry
    else
      logger.error("Failed after #{retries} retries: #{e.message}")
      raise e
    end
  rescue StandardError => e
    retries += 1
    if retries < max_retries
      logger.warn("Unexpected error occurred. Retrying #{retries}/#{max_retries}: #{e.message}")
      retry
    else
      logger.error("Failed after #{retries} retries: #{e.message}")
      raise e
    end
  end
end

def check_call_status(client, call_sid, logger, status_queue, timeout = 300)
  start_time = Time.now
  loop do
    sleep(10)
    call = client.calls(call_sid).fetch
    logger.info("Call status: #{call.status}")

    case call.status
    when 'completed'
      status_queue.push('completed')
      break
    when 'busy', 'failed', 'no-answer', 'rejected'
      status_queue.push(call.status)
      break
    else
      logger.info('Call still in progress, checking again...')
    end

    if Time.now - start_time > timeout
      logger.error("Timeout reached for call SID: #{call_sid}")
      status_queue.push('timeout')
      break
    end
  end
end

def process_calls(client, csv_file, twilio_number, intro_audio, outro_audio, logger)
  logger.info('Starting call processing...')
  table = CSV.table(csv_file, converters: nil)

  pending_calls = table.select { |row| row[:recording_url].nil? || row[:recording_url].strip.empty? }
  if pending_calls.empty?
    logger.info("No pending calls to process. Exiting.")
    return
  end

  threads = []
  status_queue = Queue.new

  table.each_with_index do |row, index|
    contact_id = row[:contact_id]
    phone_number = row[:telephone]
    recording_url = row[:recording_url]

    next unless recording_url.nil? || recording_url.strip.empty?

    if contact_id.nil?
      logger.error("No Contact ID specified at row #{index + 1}")
      next
    end

    if phone_number.nil? || phone_number.strip.empty?
      logger.error("No phone number specified for Contact ID: #{contact_id}")
      next
    end

    if phone_number.include?('W')
      phone_number, extension = phone_number.split('W', 2)
      logger.info("Detected DTMF. Dialing #{phone_number} and sending DTMF tones: #{extension}")
      twiml = "<Response><Pause length='1'/><Play>#{intro_audio}</Play><Pause length='1'/><Play>#{outro_audio}</Play><SendDigits>#{extension}</SendDigits></Response>"
    else
      logger.info("Dialing phone number: #{phone_number}")
      twiml = "<Response><Pause length='1'/><Play>#{intro_audio}</Play><Pause length='1'/><Play>#{outro_audio}</Play></Response>"
    end

    threads << Thread.new do
      with_retry(logger:) do
        # Initiate the call
        call = client.calls.create(
          from: twilio_number,
          to: phone_number,
          twiml:,
          record: true
        )
        logger.info("Call initiated to #{phone_number}, Call SID: #{call.sid}")

        check_call_status(client, call.sid, logger, status_queue)

        call_status = status_queue.pop
        if call_status == 'completed'
          logger.info("Call completed for Contact ID: #{contact_id}")
        else
          logger.error("Call failed or was not answered for Contact ID: #{contact_id}, Status: #{call_status}")
        end

        check_recording_status(client, call.sid, contact_id, csv_file, index, logger)
      end
    end
  end

  logger.info('Waiting for all threads to finish...')
  threads.each(&:join)
  logger.info('All threads have finished. Script is terminating.')
end

def check_recording_status(client, call_sid, contact_id, csv_file, index, logger, timeout = 300)
  with_retry(logger: logger) do
    start_time = Time.now
    loop do
      sleep(10)
      begin
        recordings = client.recordings.list(call_sid: call_sid)
        if recordings.any?
          recording = recordings.first
          recording_url = "https://api.twilio.com#{recording.uri.gsub('.json', '.mp3')}"
          logger.info("Recording URL for Contact ID #{contact_id}: #{recording_url}")
          update_csv(csv_file, index, 'recording_url', recording_url, logger)
          break
        else
          logger.info("No recording found yet for call SID: #{call_sid}, retrying...")
        end
      rescue StandardError => e
        logger.error("Error checking recording status for SID #{call_sid}: #{e.message}")
        break
      end

      if Time.now - start_time > timeout
        logger.error("Timeout reached while checking recording for SID #{call_sid}")
        break
      end
    end
  end
end

process_calls(client, csv_file, twilio_number, intro_audio, outro_audio, logger)
