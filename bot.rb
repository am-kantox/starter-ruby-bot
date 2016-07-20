require 'slack-ruby-client'
require 'logging'

require 'yandex-api'
Yandex::API::Translate.load 'yandex_translate.yml'

ISO_639_2 = 'http://www.loc.gov/standards/iso639-2/ISO-639-2_utf-8.txt'.freeze
LANG_3_TO_COUNTRY = 'http://www.ethnologue.com/sites/default/files/LanguageCodes.tab'.freeze
LANG_TO_COUNTRY = File.join 'resources', 'lang_to_country.yml'

require 'open-uri'
require 'yaml'
def lang_to_country
  @lang_to_country ||= if File.exist?(LANG_TO_COUNTRY)
    YAML.load File.read LANG_TO_COUNTRY
  else
    open(ISO_639_2) do |c2l|
      l2l = c2l.read.split(/\R/).map do |w|
        w = w.split('|')
        [w[2], w[0]]
      end.to_h.invert

      open(LANG_3_TO_COUNTRY) do |l2c|
        l2c.read.split(/\R/)[1..-1].map do |w|
          w = w.split(/\t/)
          [l2l[w[0]], w[1].downcase]
        end.to_h
      end
    end.tap { |l2c| File.write(LANG_TO_COUNTRY, l2c.to_yaml) }
  end.tap { |h| h.default_proc = ->(_, key) { key } }
end

logger = Logging.logger(STDOUT)
logger.level = :info

Slack.configure do |config|
  config.token = ENV['SLACK_TOKEN']
  if not config.token
    logger.fatal('Missing ENV[SLACK_TOKEN]! Exiting program')
    exit
  end
end

client = Slack::RealTime::Client.new

# listen for hello (connection) event - https://api.slack.com/events/hello
client.on :hello do
  logger.debug("Connected '#{client.self['name']}' to '#{client.team['name']}' team at https://#{client.team['domain']}.slack.com.")
end

# listen for channel_joined event - https://api.slack.com/events/channel_joined
client.on :channel_joined do |data|
  if joiner_is_bot?(client, data)
    client.message channel: data['channel']['id'], text: "Thanks for the invite! I don\'t do much yet, but #{help}"
    logger.debug("#{client.self['name']} joined channel #{data['channel']['id']}")
  else
    logger.debug("Someone far less important than #{client.self['name']} joined #{data['channel']['id']}")
  end
end

# listen for message event - https://api.slack.com/events/message
client.on :message do |data|
  case data['text']
  when 'hi', 'bot hi' then
    client.typing channel: data['channel']
    sleep 1
    client.message channel: data['channel'], text: "Hello <@#{data['user']}>. Qué tal?\n#{help}"
    logger.debug("<@#{data['user']}> said hi")

    if direct_message?(data)
      client.message channel: data['channel'], text: "It\'s nice to talk to you directly."
      logger.debug("And it was a direct message")
    end

  when bot_mentioned(client)
    data['text'] = "#{$`} #{$'}".strip
    data['text'].prepend('⇒en ') unless data['text'] =~ translate_regex
    logger.debug("Translation requested in channel #{data['channel']}.")
    translate client, data, logger

  when 'bot help', 'help' then
    client.message channel: data['channel'], text: help
    logger.debug("A call for help")

  # https://translate.yandex.ru/?text=hello%20world&lang=en-ru
  when translate_regex
    translate client, data, logger

  when /^bot/ then
    client.message channel: data['channel'], text: "Sorry <@#{data['user']}>, I don\'t understand. \n#{help}"
    logger.debug("Unknown command")
  end
end

def translate client, data, logger
  lang, text = data['text'].scan(/\A(?:bot\s+)?(?:2|⇒|to|tr)\s*(\w{2})\s+(.*)\z/).first
  raise "Invalid input" unless lang.is_a?(String) && text.is_a?(String) && text.length > 0
  result = Yandex::API::Translate.do(text, lang)
  src, dst = if result['code'] == 200 && result['lang'].is_a?(String) && result['lang'] =~ /\A\w{2}-\w{2}\z/
    src_lang, dst_lang = result['lang'].split('-').map { |l| lang_to_country[l.downcase] }
    [ ":flag-#{src_lang}:", ":flag-#{dst_lang}:" ]
  else
    [ lang, 'N/A' ]
  end
  result['text'] = result['text'].join(', ') if result['text'].is_a?(Array)
  raise "Translation failed" unless result['text'].is_a?(String) && result['text'].length > 0
  client.message(channel: data['channel'], text: "#{src}  #{text}  ⇒  #{dst}  *#{result['text']}*")
  logger.debug("Translated “#{text}” to “#{result['text']}”")
rescue => e
  client.web_client.chat_postMessage(format_yandex_reject data['channel'], e.message, lang, text, result)
  logger.debug("Failed “#{text}” to “#{lang}”")
end

def direct_message?(data)
  # direct message channles start with a 'D'
  data['channel'][0] == 'D'
end

def bot_mentioned(client)
  # match on any instances of `<@bot_id>` in the message
  /\<\@#{client.self['id']}\>+/
end

def translate_regex
  /\A(bot\s+)?(?:2|⇒|to|tr)\s*(\w{2})\s+/
end

def joiner_is_bot?(client, data)
 /^\<\@#{client.self['id']}\>/.match data['channel']['latest']['text']
end

def help
  %Q(I will respond to the following messages: \n
      `bot hi` for a simple message.\n
      `2es` or `⇒ru` or `to en` for a translations to a desired language.\n
      `@<your bot\'s name>` to demonstrate detecting a mention.\n
      `bot help` to see this again.)
end

def format_yandex_link text, lang, src_lang = nil
  src = (src_lang || (src == 'en' ? 'es' : 'en')) << '-'
  "https://translate.yandex.ru/?text=#{text}&lang=#{src}#{lang}"
end

def format_yandex_reject channel, message, lang, text, result
  msg = "Failed:\n_Destination language:_ “*#{lang}*”.\n_Text:_ “*#{text}*”.\n_Error:_ #{message}\n_Result:_ #{result.inspect}"
  {
    channel: channel,
      as_user: true,
      attachments: [
        {
          fallback: msg,
          pretext: ':thumbsdown: Yandex.Translate was unable to process your request.',
          title: 'Not all services are equally available.',
          title_link: format_yandex_link(text, lang),
          text: msg,
          mrkdwn_in: [:text],
          color: '#A02020'
        }
      ]
  }
end

def post_message_payload(data)
  main_msg = 'Beep Beep Boop is a ridiculously simple hosting platform for your Slackbots.'
  {
    channel: data['channel'],
      as_user: true,
      attachments: [
        {
          fallback: main_msg,
          pretext: 'We bring bots to life. :sunglasses: :thumbsup:',
          title: 'Host, deploy and share your bot in seconds.',
          image_url: 'https://storage.googleapis.com/beepboophq/_assets/bot-1.22f6fb.png',
          title_link: 'https://beepboophq.com/',
          text: main_msg,
          color: '#7CD197'
        }
      ]
  }
end

client.start!
