#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *hold_me*) continue ;;
    *exit_me*) exit 1 ;;
    *bad_json*) result='not json' ;;
    *'1 + 1'*) result='2' ;;
    *fail_me*) result='{"error":"evaluation failed"}' ;;
    *) result='42' ;;
  esac
  printf '__START__\n%s\n__END__\n' "$result"
done
