import sys;
import from email { message_from_string, policy }
import from email.message { EmailMessage }
import from pathlib { Path }
import from jaclang.scale.emailer.emailer { Emailer, EmailAttachment }
import from jaclang.scale.emailer.factory { create as create_emailer, register }
import from jaclang.server.identity.auth_tokens {
    AuthTokenStore,
    reset_auth_token_store
}


obj _RecordingEmailer(Emailer) {
    has sent: list[dict[str, any]] = [];

    override def is_ready -> bool {
        return True;
    }

    override def send_email(
        to_addr: str,
        subject: str,
        body_text: str,
        body_html: (str | None) = None,
        from_addr: (str | None) = None,
        reply_to: (str | None) = None,
        attachments: (list[EmailAttachment] | None) = None
    ) -> bool {
        self.sent.append(
            {
                "to": to_addr,
                "subject": subject,
                "body": body_text,
                "from": from_addr or self.from_address
            }
        );
        return True;
    }
}


test "factory_returns_none_when_provider_unset" {
    cfg = {"provider": "", "from_address": "x@y.z", "smtp": {}};
    assert create_emailer(cfg) is None;
}

test "factory_builds_smtp_provider" {
    import from jaclang.scale.emailer.emailers { SMTPEmailer }
    cfg = {
        "provider": "smtp",
        "from_address": "noreply@example.com",
        "smtp": {"host": "smtp.example.com", "port": 587, "use_tls": True}
    };
    emailer = create_emailer(cfg);
    assert emailer is not None;
    assert isinstance(emailer, SMTPEmailer);
    assert emailer.from_address == "noreply@example.com";
    assert emailer.host == "smtp.example.com";
    assert emailer.port == 587;
}

def _smtp_message(
    body_html: (str | None), reply_to: (str | None), attachments: list[EmailAttachment]
) -> EmailMessage {
    # The message SMTPEmailer would send, read back as a mail client reads it.
    import from jaclang.scale.emailer.emailers { SMTPEmailer }
    emailer = SMTPEmailer(
        config={"smtp": {"host": "smtp.example.com"}},
        from_address="noreply@example.com"
    );
    built = emailer._build_message(
        "noreply@example.com",
        "user@x.y",
        "Your tickets",
        "See attached.",
        body_html,
        reply_to,
        attachments
    );
    return message_from_string(built.as_string(), policy=policy.default);
}

test "smtp_plain_message_is_text_and_html_alternatives" {
    msg = _smtp_message("<p>See attached.</p>", None, []);
    assert msg.get_content_type() == "multipart/alternative";
    assert msg["Reply-To"] is None;
    assert msg.get_body(preferencelist=("plain", )).get_content().strip()
        == "See attached.";
    assert "<p>See attached.</p>"
        in msg.get_body(preferencelist=("html", )).get_content();
}

test "smtp_message_has_reply_to_and_inline_and_attached_files" {
    msg = _smtp_message(
        '<img src="cid:qr-1">',
        "Box Office <boxoffice@example.com>",
        [
            EmailAttachment(
                filename="qr.png",
                content=b"PNG-BYTES",
                mime_type="image/png",
                content_id="qr-1"
            ),
            EmailAttachment(
                filename="ticket.pdf", content=b"PDF-BYTES", mime_type="application/pdf"
            )
        ]
    );
    assert msg["Reply-To"] == "Box Office <boxoffice@example.com>";
    assert msg.get_content_type() == "multipart/mixed";
    related = msg.get_body(preferencelist=("related", ));
    assert related is not None;
    image = [
        p
        for p in related.iter_parts()
        if p.get_content_type() == "image/png"
    ][0];
    assert image["Content-ID"] == "<qr-1>";
    assert image.get_content() == b"PNG-BYTES";
    attached = list(msg.iter_attachments());
    assert [a.get_filename() for a in attached] == ["ticket.pdf"];
    assert attached[0].get_content() == b"PDF-BYTES";
}

test "smtp_inline_file_without_html_is_attached" {
    msg = _smtp_message(
        None,
        None,
        [
            EmailAttachment(
                filename="qr.png",
                content=b"PNG-BYTES",
                mime_type="image/png",
                content_id="qr-1"
            )
        ]
    );
    assert [a.get_filename() for a in msg.iter_attachments()] == ["qr.png"];
}

test "factory_uses_registered_name" {
    register("recording", _RecordingEmailer);
    cfg = {"provider": "recording", "from_address": "test@x.y"};
    emailer = create_emailer(cfg);
    assert emailer is not None;
    assert isinstance(emailer, _RecordingEmailer);
    assert emailer.is_ready();
    sent = emailer.send_email(to_addr="user@x.y", subject="hi", body_text="body");
    assert sent == True;
    assert emailer.sent[0]["to"] == "user@x.y";
}

test "factory_imports_dotted_path" {
    fixtures_dir = Path(__file__).parent.parent / "fixtures" / "identity_api";
    sys.path.insert(0, str(fixtures_dir));
    try {
        cfg = {
            "provider": "test_emailer_fake:FakeEmailer",
            "from_address": "x@y.z",
            "smtp": {}
        };
        emailer = create_emailer(cfg);
        assert emailer is not None;
        assert emailer.is_ready();
        ok = emailer.send_email(to_addr="dst@x.y", subject="s", body_text="b");
        assert ok == True;
    } finally {
        if str(fixtures_dir) in sys.path {
            sys.path.remove(str(fixtures_dir));
        }
    }
}

test "factory_returns_none_for_invalid_provider" {
    cfg = {
        "provider": "definitely.not.a.module:NoClass",
        "from_address": "x@y.z",
        "smtp": {}
    };

    assert create_emailer(cfg) is None;
}

test "auth_tokens_create_and_consume_single_use" {
    reset_auth_token_store();
    store = AuthTokenStore.instance();
    raw = store.create_token(
        user_id="u1", purpose="reset", ttl_seconds=60, identity_value="a@b.c"
    );
    assert len(raw) > 16;
    record = store.consume_token(raw, "reset");
    assert record is not None;
    assert record["user_id"] == "u1";
    assert record["identity_value"] == "a@b.c";

    assert store.consume_token(raw, "reset") is None;
}

test "auth_tokens_purpose_isolation" {
    reset_auth_token_store();
    store = AuthTokenStore.instance();
    raw = store.create_token(user_id="u2", purpose="reset", ttl_seconds=60);

    assert store.consume_token(raw, "verify") is None;

    assert store.consume_token(raw, "reset") is not None;
}

test "auth_tokens_expiry" {
    reset_auth_token_store();
    store = AuthTokenStore.instance();
    raw = store.create_token(user_id="u3", purpose="reset", ttl_seconds=-1);
    assert store.consume_token(raw, "reset") is None;
}

test "auth_tokens_revoke_all_for_user" {
    reset_auth_token_store();
    store = AuthTokenStore.instance();
    t1 = store.create_token(user_id="u4", purpose="reset", ttl_seconds=60);
    t2 = store.create_token(user_id="u4", purpose="reset", ttl_seconds=60);

    t3 = store.create_token(user_id="u4", purpose="verify", ttl_seconds=60);
    n = store.revoke_user_tokens("u4", "reset");
    assert n == 2;
    assert store.consume_token(t1, "reset") is None;
    assert store.consume_token(t2, "reset") is None;
    assert store.consume_token(t3, "verify") is not None;
}

test "auth_tokens_hash_is_stable" {
    h1 = AuthTokenStore.hash_token("abc123");
    h2 = AuthTokenStore.hash_token("abc123");
    assert h1 == h2;
    assert h1 != AuthTokenStore.hash_token("abc124");
    assert len(h1) == 64;
}
