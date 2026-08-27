#!/bin/zsh

set -euo pipefail

collector_directory=${0:A:h}

if (( $# == 0 )); then
  print "Select stadiums to collect:"
  print "  1) All Premier League clubs"
  print "  2) All Championship clubs"
  print "  3) Major teams (app Club Elo threshold)"
  print "  4) Everything above"
  read "selection?Choice [1-4]: "

  case "$selection" in
    1) collection_scope="premier-league" ;;
    2) collection_scope="championship" ;;
    3) collection_scope="major" ;;
    4) collection_scope="all" ;;
    *) print -u2 "Invalid choice: $selection"; exit 2 ;;
  esac
else
  collection_scope=$1
  shift
  case "$collection_scope" in
    premier) collection_scope="premier-league" ;;
    europe|european) collection_scope="major" ;;
    premier-league|championship|major|all) ;;
    *)
      print -u2 "Usage: $0 [premier-league|championship|major|all] [collector options]"
      exit 2
      ;;
  esac
fi

exec "$collector_directory/collect_all.py" --scope "$collection_scope" "$@"
