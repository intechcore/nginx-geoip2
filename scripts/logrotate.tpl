${LOGROTATE_PATTERN} {
    ${LOGROTATE_FREQUENCY}
    rotate ${LOGROTATE_KEEP}
    missingok
    notifempty
    sharedscripts
${LOGROTATE_COMPRESS_BLOCK}
    postrotate
        nginx -s reopen >/dev/null 2>&1 || true
    endscript
}
