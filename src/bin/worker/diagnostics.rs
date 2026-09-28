//! Opt-in panic reporting for the helper; the inventory library has no telemetry.
use sentry::protocol::{DebugImage, Event, Exception, Frame, Mechanism, Stacktrace};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

// The reader revokes consent even while the main thread is busy with a probe.
static ENABLED: AtomicBool = AtomicBool::new(false);
pub fn consent_enabled() -> bool {
    ENABLED.load(Ordering::SeqCst)
}
pub fn consent(enabled: bool) {
    ENABLED.store(enabled, Ordering::SeqCst);
}

#[derive(Default)]
pub struct Diagnostics(Option<Arc<sentry::Client>>);
impl Diagnostics {
    pub fn configure(&mut self, enabled: bool) {
        if enabled == self.0.is_some() {
            return;
        }
        if let Some(client) = self.0.take() {
            client.close(Some(Duration::ZERO));
        }
        if !enabled {
            sentry::Hub::main().bind_client(None);
            return;
        }
        let mut options = sentry::ClientOptions::default();
        options.dsn = Some(
            include_str!("../../../config/Sentry.dsn")
                .trim()
                .parse()
                .expect("bundled DSN"),
        );
        options.release = Some(
            option_env!("BURROWBOLT_SENTRY_RELEASE")
                .unwrap_or("burrowbolt-worker@development")
                .into(),
        );
        options.environment = Some(
            option_env!("BURROWBOLT_SENTRY_ENVIRONMENT")
                .unwrap_or("development")
                .into(),
        );
        options.send_default_pii = false;
        options.max_breadcrumbs = 0;
        options.shutdown_timeout = Duration::from_secs(2);
        options.before_send = Some(Arc::new(filter));
        let mut options = sentry::apply_defaults(options);
        // Never let an inherited SSL_VERIFY override certificate verification.
        options.accept_invalid_certs = false;
        let client = Arc::new(sentry::Client::from(options));
        sentry::Hub::main().bind_client(Some(client.clone()));
        self.0 = Some(client);
    }
}
impl Drop for Diagnostics {
    fn drop(&mut self) {
        if let Some(client) = &self.0 {
            client.close(Some(Duration::from_secs(2)));
        }
    }
}

fn stack(old: Stacktrace) -> Stacktrace {
    Stacktrace {
        frames: old
            .frames
            .into_iter()
            .map(|frame| Frame {
                function: frame.function,
                symbol: frame.symbol,
                lineno: frame.lineno,
                colno: frame.colno,
                in_app: frame.in_app,
                instruction_addr: frame.instruction_addr,
                image_addr: frame.image_addr,
                symbol_addr: frame.symbol_addr,
                ..Default::default()
            })
            .collect(),
        ..Default::default()
    }
}
fn filter(event: Event<'static>) -> Option<Event<'static>> {
    consent_enabled().then(|| scrub(event))
}
fn scrub(source: Event<'static>) -> Event<'static> {
    let mut event = Event {
        event_id: source.event_id,
        timestamp: source.timestamp,
        level: source.level,
        platform: source.platform,
        // Prevent ingestion from inferring peer-IP geolocation.
        user: Some(sentry::protocol::User {
            ip_address: Some(sentry::protocol::IpAddress::Exact(
                std::net::Ipv4Addr::UNSPECIFIED.into(),
            )),
            ..Default::default()
        }),
        release: source.release,
        environment: source.environment,
        exception: source
            .exception
            .into_iter()
            .map(|old| Exception {
                ty: "RustPanic".into(),
                value: Some("Panic details withheld".into()),
                stacktrace: old.stacktrace.map(stack),
                mechanism: Some(Mechanism {
                    ty: "panic".into(),
                    handled: Some(false),
                    ..Default::default()
                }),
                ..Default::default()
            })
            .collect::<Vec<_>>()
            .into(),
        stacktrace: source.stacktrace.map(stack),
        ..Default::default()
    };
    event.tags.insert("component".into(), "worker".into());
    if source.tags.get("verification").map(String::as_str) == Some("sdk-panic") {
        event.tags.insert("verification".into(), "sdk-panic".into());
    }
    event.debug_meta.to_mut().images = source
        .debug_meta
        .images
        .iter()
        .filter_map(|image| {
            let basename = |path: &str| path.rsplit('/').next().unwrap_or("image").to_owned();
            match image {
                DebugImage::Apple(old) => {
                    let mut image = old.clone();
                    image.name = basename(&image.name);
                    Some(image.into())
                }
                DebugImage::Symbolic(old) => {
                    let mut image = old.clone();
                    image.name = basename(&image.name);
                    image.debug_file = None;
                    Some(image.into())
                }
                _ => None,
            }
        })
        .collect();
    event
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reports_only_code_stacks_and_build_metadata() {
        let secret = "/Users/private/secret-file.dmg";
        let event: Event = serde_json::from_value(serde_json::json!({
            "message":secret,"server_name":secret,"user":{"username":secret},
            "extra":{"prompt":secret},"tags":{"path":secret},"contexts":{"custom":{"path":secret}},
            "exception":{"values":[{"type":secret,"value":secret,"module":secret,
                "stacktrace":{"frames":[{"function":"worker_function","filename":secret,"abs_path":secret,
                    "vars":{"path":secret},"context_line":secret,"instruction_addr":"0x1234"}]}}]},
            "threads":{"values":[{"name":secret}]}
        })).unwrap();
        consent(false);
        assert!(filter(event.clone()).is_none());
        consent(true);
        let safe = filter(event.clone()).unwrap();
        consent(false);
        assert!(
            filter(event).is_none(),
            "Revoked consent still accepted an event"
        );
        let result = serde_json::to_string(&safe).unwrap();
        assert!(result.contains("0.0.0.0"));
        assert!(!result.contains(secret));
        assert!(!result.contains("secret-file"));
        assert!(result.contains("worker_function") && result.contains("0x1234"));
        let mut diagnostics = Diagnostics::default();
        diagnostics.configure(false);
        assert!(diagnostics.0.is_none());
    }

    #[test]
    #[ignore = "Sends a synthetic panic to the configured Sentry project; run explicitly"]
    #[should_panic(expected = "PRIVATE_PANIC_MARKER")]
    fn verify_sdk_panic() {
        let mut diagnostics = Diagnostics::default();
        consent(true);
        diagnostics.configure(true);
        sentry::configure_scope(|scope| scope.set_tag("verification", "sdk-panic"));
        panic!("PRIVATE_PANIC_MARKER /Users/private/secret-file.dmg");
    }
}
