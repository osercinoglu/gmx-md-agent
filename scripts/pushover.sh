#!/usr/bin/env bash
# Vendored from https://github.com/akusei/pushover-bash (pushover.sh, v1.21)
# A bash script to send Pushover notifications. Requires curl.
# Usage: pushover.sh <-t|--token apikey> <-u|--user userkey> [options] <MESSAGE>
# Configuration is sourced from /etc/pushover/pushover-config and ~/.pushover/pushover-config.

set -o errexit
set -o nounset

readonly VERSION=1.21
readonly API_URL="https://api.pushover.net/1/messages.json"
readonly CONFIG_FILE="pushover-config"
readonly DEFAULT_CONFIG="/etc/pushover/${CONFIG_FILE}"
readonly USER_OVERRIDE=~/.pushover/${CONFIG_FILE}
readonly EXPIRE_DEFAULT=180
readonly RETRY_DEFAULT=30
HIDE_REPLY=true

showHelp()
{
        local script=`basename "$0"`
        echo "Send Pushover v${VERSION} scripted by Nathan Martini"
        echo "Push notifications to your Android, iOS, or desktop devices"
        echo
        echo "NOTE: This script requires an account at http://www.pushover.net"
        echo
        echo "usage: ${script} <-t|--token apikey> <-u|--user userkey> [options] <MESSAGE>"
        echo
        echo "  MESSAGE                    The message to send; supports HTML formatting"
        echo "  -t,  --token APIKEY        The pushover.net API Key for your application"
        echo "  -u,  --user USERKEY        Your pushover.net user key"
        echo "  -a,  --attachment filename The Picture you want to send"
        echo "  -T,  --title TITLE         Title of the message"
        echo "  -d,  --device NAME         Comma seperated list of devices to receive message"
        echo "  -U,  --url URL             URL to send with message"
        echo "       --url-title URLTITLE  Title of the URL"
        echo "  -H,  --html                Enable HTML formatting"
        echo "  -M,  --monospace           Enable monospace messages"
        echo "  -p,  --priority PRIORITY   Priority of the message (-2..2)"
        echo "  -e,  --expire SECONDS      Expiration time for priority-2 (default ${EXPIRE_DEFAULT})"
        echo "  -r,  --retry COUNT         Retry period for priority-2 (default ${RETRY_DEFAULT})"
        echo "  -s,  --sound SOUND         Notification sound to play"
        echo "  -v,  --verbose             Return API reply to stdout"
        echo
}

curl --version > /dev/null 2>&1 || { echo "This script requires curl; aborting."; echo; exit 1; }

if [ -f ${DEFAULT_CONFIG} ]; then
  source ${DEFAULT_CONFIG}
fi
if [ -f ${USER_OVERRIDE} ]; then
  source ${USER_OVERRIDE}
fi

while [ $# -gt 0 ]
do
  case "${1:-}" in
    -t|--token)       api_token="${2:-}";  shift ;;
    -u|--user)        user_key="${2:-}";   shift ;;
    -a|--attachment)  attachment="${2:-}"; shift ;;
    -T|--title)       title="${2:-}";      shift ;;
    -d|--device)      device="${2:-}";     shift ;;
    -U|--url)         url="${2:-}";        shift ;;
    --url-title)      url_title="${2:-}";  shift ;;
    -H|--html)        html=1 ;;
    -M|--monospace)   monospace=1 ;;
    -p|--priority)    priority="${2:-}";   shift ;;
    -s|--sound)       sound="${2:-}";      shift ;;
    -e|--expire)      expire="${2:-}";     shift ;;
    -r|--retry)       retry="${2:-}";      shift ;;
    -v|--verbose)     unset HIDE_REPLY ;;
    -h|--help)        showHelp; exit ;;
    *)                message="${*:1}"; break ;;
  esac
  shift
done

if [ ${priority:-0} -eq 2 ]; then
  [ -z "${expire:-}" ] && expire=${EXPIRE_DEFAULT}
  [ -z "${retry:-}"  ] && retry=${RETRY_DEFAULT}
fi

[ -z "${api_token:-}" ] && { echo "-t|--token must be set"; exit 1; }
[ -z "${user_key:-}"  ] && { echo "-u|--user must be set";  exit 1; }
[ -z "${message:-}"   ] && { echo "positional argument MESSAGE must be set"; exit 1; }

if [ ! -z "${html:-}" ] && [ ! -z "${monospace:-}" ]; then
  echo "--html and --monospace are mutually exclusive"; exit 1
fi

if [ ! -z "${attachment:-}" ] && [ ! -f "${attachment}" ]; then
  echo "${attachment} not found"; exit 1
fi

if [ -z "${attachment:-}" ]; then
  json="{\"token\":\"${api_token}\",\"user\":\"${user_key}\",\"message\":\"${message}\""
  if [ "${device:-}"    ]; then json="${json},\"device\":\"${device}\""; fi
  if [ "${title:-}"     ]; then json="${json},\"title\":\"${title}\""; fi
  if [ "${url:-}"       ]; then json="${json},\"url\":\"${url}\""; fi
  if [ "${url_title:-}" ]; then json="${json},\"url_title\":\"${url_title}\""; fi
  if [ "${html:-}"      ]; then json="${json},\"html\":1"; fi
  if [ "${monospace:-}" ]; then json="${json},\"monospace\":1"; fi
  if [ "${priority:-}"  ]; then json="${json},\"priority\":${priority}"; fi
  if [ "${expire:-}"    ]; then json="${json},\"expire\":${expire}"; fi
  if [ "${retry:-}"     ]; then json="${json},\"retry\":${retry}"; fi
  if [ "${sound:-}"     ]; then json="${json},\"sound\":\"${sound}\""; fi
  json="${json}}"

  curl --fail -s ${HIDE_REPLY:+ -o /dev/null} \
    -H "Content-Type: application/json" \
    -d "${json}" \
    "${API_URL}" 2>&1
else
  curl --fail -s ${HIDE_REPLY:+ -o /dev/null} \
    --form-string "token=${api_token}" \
    --form-string "user=${user_key}" \
    --form-string "message=${message}" \
    --form "attachment=@${attachment}" \
    ${html:+ --form-string "html=1"} \
    ${monospace:+ --form-string "monospace=1"} \
    ${priority:+ --form-string "priority=${priority}"} \
    ${sound:+ --form-string "sound=${sound}"} \
    ${device:+ --form-string "device=${device}"} \
    ${title:+ --form-string "title=${title}"} \
    "${API_URL}" 2>&1
fi
