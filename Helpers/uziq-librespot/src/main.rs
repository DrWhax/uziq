use std::{env, path::PathBuf, process::ExitCode, time::Duration};

use librespot::{
    connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc},
    core::{
        SpotifyUri,
        authentication::Credentials,
        cache::Cache,
        config::{DeviceType, SessionConfig},
        session::Session,
    },
    metadata::audio::UniqueFields,
    oauth::OAuthClientBuilder,
    playback::{
        audio_backend,
        config::{AudioFormat, Bitrate, PlayerConfig},
        mixer::{self, MixerConfig},
        player::{Player, PlayerEvent},
    },
};
use log::LevelFilter;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter},
    sync::mpsc,
};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const OAUTH_SCOPES: &[&str] = &[
    "app-remote-control",
    "streaming",
    "user-modify-playback-state",
];

#[derive(Debug)]
struct Options {
    system_cache: PathBuf,
    oauth_port: u16,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum Command {
    LoadContext {
        uri: String,
        offset_uri: Option<String>,
        #[serde(default)]
        position_ms: u32,
    },
    LoadTracks {
        uris: Vec<String>,
        offset_uri: Option<String>,
        #[serde(default)]
        position_ms: u32,
    },
    Play,
    Toggle,
    Pause,
    Next,
    Previous,
    Seek {
        position_ms: u32,
    },
    SetVolume {
        volume: f64,
    },
    Ping,
    Shutdown,
}

#[tokio::main]
async fn main() -> ExitCode {
    env_logger::builder()
        .filter_module("librespot", LevelFilter::Info)
        .filter_module("uziq_librespot", LevelFilter::Info)
        .init();

    let options = match parse_options() {
        Ok(Some(options)) => options,
        Ok(None) => return ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            print_usage();
            return ExitCode::from(2);
        }
    };

    let (event_sender, event_receiver) = mpsc::unbounded_channel();
    let writer = tokio::spawn(write_events(event_receiver));
    emit(
        &event_sender,
        json!({ "event": "status", "state": "starting" }),
    );

    if let Err(error) = run(options, event_sender.clone()).await {
        emit(&event_sender, json!({ "event": "error", "message": error }));
        drop(event_sender);
        let _ = writer.await;
        return ExitCode::FAILURE;
    }

    drop(event_sender);
    let _ = writer.await;
    ExitCode::SUCCESS
}

async fn run(options: Options, events: mpsc::UnboundedSender<Value>) -> Result<(), String> {
    let cache = Cache::new(
        Some(options.system_cache.clone()),
        Some(options.system_cache.clone()),
        None::<PathBuf>,
        None,
    )
    .map_err(|error| format!("Could not open the librespot credential cache: {error}"))?;

    let session_config = SessionConfig {
        autoplay: Some(false),
        ..SessionConfig::default()
    };
    let credentials = if let Some(credentials) = cache.credentials() {
        credentials
    } else {
        emit(
            &events,
            json!({ "event": "status", "state": "authenticating" }),
        );
        let redirect_uri = format!("http://127.0.0.1:{}/login", options.oauth_port);
        let client = OAuthClientBuilder::new(
            &session_config.client_id,
            &redirect_uri,
            OAUTH_SCOPES.to_vec(),
        )
        .open_in_browser()
        .build()
        .map_err(|error| format!("Could not start Spotify login: {error}"))?;
        let token = client
            .get_access_token()
            .map_err(|error| format!("Spotify login failed: {error}"))?;
        Credentials::with_access_token(token.access_token)
    };

    let session = Session::new(session_config, Some(cache));
    let mixer_builder = mixer::find(None).ok_or("No librespot mixer is available")?;
    let mixer = mixer_builder(MixerConfig::default())
        .map_err(|error| format!("Could not create the librespot mixer: {error}"))?;
    let backend = audio_backend::find(Some("rodio".to_owned()))
        .ok_or("The librespot Rodio audio backend is unavailable")?;
    let player_config = PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        position_update_interval: Some(Duration::from_secs(5)),
        ..PlayerConfig::default()
    };
    let soft_volume = mixer.get_soft_volume();
    let player = Player::new(player_config, session.clone(), soft_volume, move || {
        backend(None, AudioFormat::S16)
    });
    let player_events = player.get_player_event_channel();

    let connect_config = ConnectConfig {
        name: "Uziq".to_owned(),
        device_type: DeviceType::Computer,
        initial_volume: u16::MAX,
        ..ConnectConfig::default()
    };
    let (spirc, spirc_task) =
        Spirc::new(connect_config, session.clone(), credentials, player, mixer)
            .await
            .map_err(|error| format!("Could not initialize Spotify Connect: {error}"))?;

    emit(
        &events,
        json!({
            "event": "status",
            "state": "ready",
            "username": session.username(),
        }),
    );
    let player_event_task = tokio::spawn(forward_player_events(player_events, events.clone()));
    tokio::pin!(spirc_task);

    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    loop {
        tokio::select! {
            line = lines.next_line() => {
                match line {
                    Ok(Some(line)) => {
                        match handle_command(&spirc, &events, &line) {
                            Ok(true) => break,
                            Ok(false) => {}
                            Err(error) => emit(
                                &events,
                                json!({ "event": "error", "message": error }),
                            ),
                        }
                    }
                    Ok(None) => break,
                    Err(error) => return Err(format!("Could not read a command from Uziq: {error}")),
                }
            }
            _ = &mut spirc_task => {
                return Err("The Spotify Connect session ended unexpectedly".to_owned());
            }
            _ = tokio::signal::ctrl_c() => break,
        }
    }

    let _ = spirc.shutdown();
    player_event_task.abort();
    Ok(())
}

fn handle_command(
    spirc: &Spirc,
    events: &mpsc::UnboundedSender<Value>,
    line: &str,
) -> Result<bool, String> {
    let command: Command = serde_json::from_str(line).map_err(|error| {
        emit(
            events,
            json!({ "event": "error", "message": format!("Invalid Uziq command: {error}") }),
        );
        format!("Invalid Uziq command: {error}")
    })?;

    let result = match command {
        Command::LoadContext {
            uri,
            offset_uri,
            position_ms,
        } => spirc.activate().and_then(|_| {
            spirc.load(LoadRequest::from_context_uri(
                uri,
                load_options(offset_uri, position_ms),
            ))
        }),
        Command::LoadTracks {
            uris,
            offset_uri,
            position_ms,
        } => {
            if uris.is_empty() {
                return Err("Cannot load an empty Spotify track list".to_owned());
            }
            spirc.activate().and_then(|_| {
                spirc.load(LoadRequest::from_tracks(
                    uris,
                    load_options(offset_uri, position_ms),
                ))
            })
        }
        Command::Play => spirc.play(),
        Command::Toggle => spirc.play_pause(),
        Command::Pause => spirc.pause(),
        Command::Next => spirc.next(),
        Command::Previous => spirc.prev(),
        Command::Seek { position_ms } => spirc.set_position_ms(position_ms),
        Command::SetVolume { volume } => {
            let normalized = if volume.is_finite() {
                volume.clamp(0.0, 1.0)
            } else {
                1.0
            };
            spirc.set_volume((normalized * f64::from(u16::MAX)).round() as u16)
        }
        Command::Ping => {
            emit(events, json!({ "event": "pong" }));
            return Ok(false);
        }
        Command::Shutdown => return Ok(true),
    };

    result.map_err(|error| format!("Spotify playback command failed: {error}"))?;
    Ok(false)
}

fn load_options(offset_uri: Option<String>, position_ms: u32) -> LoadRequestOptions {
    LoadRequestOptions {
        start_playing: true,
        seek_to: position_ms,
        playing_track: offset_uri.map(PlayingTrack::Uri),
        ..LoadRequestOptions::default()
    }
}

async fn forward_player_events(
    mut player_events: librespot::playback::player::PlayerEventChannel,
    events: mpsc::UnboundedSender<Value>,
) {
    while let Some(event) = player_events.recv().await {
        let value = match event {
            PlayerEvent::TrackChanged { audio_item } => {
                let (artist, album) = match &audio_item.unique_fields {
                    UniqueFields::Track { artists, album, .. } => (
                        artists
                            .iter()
                            .map(|artist| artist.name.as_str())
                            .collect::<Vec<_>>()
                            .join(", "),
                        album.clone(),
                    ),
                    UniqueFields::Local { artists, album, .. } => (
                        artists
                            .clone()
                            .unwrap_or_else(|| "Unknown Artist".to_owned()),
                        album.clone().unwrap_or_default(),
                    ),
                    UniqueFields::Episode { show_name, .. } => {
                        (show_name.clone(), show_name.clone())
                    }
                };
                let artwork_url = audio_item
                    .covers
                    .iter()
                    .max_by_key(|cover| cover.width.saturating_mul(cover.height))
                    .map(|cover| cover.url.clone());
                json!({
                    "event": "track_changed",
                    "uri": audio_item.uri,
                    "title": audio_item.name,
                    "artist": artist,
                    "album": album,
                    "artwork_url": artwork_url,
                    "duration_ms": audio_item.duration_ms,
                })
            }
            PlayerEvent::Loading {
                track_id,
                position_ms,
                ..
            } => playback_event("loading", track_id, Some(position_ms)),
            PlayerEvent::Playing {
                track_id,
                position_ms,
                ..
            } => playback_event("playing", track_id, Some(position_ms)),
            PlayerEvent::Paused {
                track_id,
                position_ms,
                ..
            } => playback_event("paused", track_id, Some(position_ms)),
            PlayerEvent::PositionChanged {
                track_id,
                position_ms,
                ..
            } => playback_event("position", track_id, Some(position_ms)),
            PlayerEvent::PositionCorrection {
                track_id,
                position_ms,
                ..
            } => playback_event("position", track_id, Some(position_ms)),
            PlayerEvent::Seeked {
                track_id,
                position_ms,
                ..
            } => playback_event("seeked", track_id, Some(position_ms)),
            PlayerEvent::EndOfTrack { track_id, .. } => {
                playback_event("end_of_track", track_id, None)
            }
            PlayerEvent::Unavailable { track_id, .. } => {
                playback_event("unavailable", track_id, None)
            }
            PlayerEvent::Stopped { track_id, .. } => playback_event("stopped", track_id, None),
            _ => continue,
        };
        emit(&events, value);
    }
}

fn playback_event(event: &str, track_id: SpotifyUri, position_ms: Option<u32>) -> Value {
    json!({
        "event": event,
        "uri": track_id.to_uri().ok(),
        "position_ms": position_ms,
    })
}

async fn write_events(mut receiver: mpsc::UnboundedReceiver<Value>) {
    let mut stdout = BufWriter::new(tokio::io::stdout());
    while let Some(event) = receiver.recv().await {
        let mut bytes = match serde_json::to_vec(&event) {
            Ok(bytes) => bytes,
            Err(_) => continue,
        };
        bytes.push(b'\n');
        if stdout.write_all(&bytes).await.is_err() || stdout.flush().await.is_err() {
            return;
        }
    }
}

fn emit(sender: &mpsc::UnboundedSender<Value>, event: Value) {
    let _ = sender.send(event);
}

fn parse_options() -> Result<Option<Options>, String> {
    let mut arguments = env::args().skip(1);
    let mut system_cache = None;
    let mut oauth_port = 5590;

    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--system-cache" => {
                system_cache = arguments.next().map(PathBuf::from);
                if system_cache.is_none() {
                    return Err("--system-cache requires a path".to_owned());
                }
            }
            "--oauth-port" => {
                let value = arguments.next().ok_or("--oauth-port requires a port")?;
                oauth_port = value
                    .parse::<u16>()
                    .ok()
                    .filter(|port| *port > 0)
                    .ok_or("--oauth-port must be between 1 and 65535")?;
            }
            "--version" | "-V" => {
                println!("uziq-librespot {VERSION} (librespot 0.8.0)");
                return Ok(None);
            }
            "--help" | "-h" => {
                print_usage();
                return Ok(None);
            }
            unknown => return Err(format!("Unknown option: {unknown}")),
        }
    }

    Ok(Some(Options {
        system_cache: system_cache.ok_or("--system-cache is required")?,
        oauth_port,
    }))
}

fn print_usage() {
    println!("Usage: uziq-librespot --system-cache PATH [--oauth-port PORT]");
}
