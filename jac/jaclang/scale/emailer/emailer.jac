obj EmailAttachment {
    has filename: str,
        content: bytes,
        mime_type: str = 'application/octet-stream',
        content_id: (str | None) = None;
}

obj Emailer {
    has config: dict[str, any] = {},
        from_address: str = '',
        enabled: bool = True;

    def send_email(
        to_addr: str,
        subject: str,
        body_text: str,
        body_html: (str | None) = None,
        from_addr: (str | None) = None,
        reply_to: (str | None) = None,
        attachments: (list[EmailAttachment] | None) = None
    ) -> bool abst;

    def is_ready -> bool {
        return self.enabled;
    }
}
