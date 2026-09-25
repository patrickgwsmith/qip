use std::io::{self, IsTerminal, Write};
#[cfg(unix)]
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::execute;
use crossterm::terminal;

use super::{BenchCandidate, StageSpec, apply_uniform};

struct TerminalGuard;

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = io::stdout().write_all(b"\x1b[0m");
        let _ = execute!(
            io::stdout(),
            terminal::LeaveAlternateScreen,
            crossterm::cursor::Show
        );
        let _ = terminal::disable_raw_mode();
    }
}

fn apply_dimensions(candidate: &mut BenchCandidate, spec: &StageSpec) -> Result<(), String> {
    let (columns, lines) = terminal::size().unwrap_or((80, 24));
    for (name, value) in [("columns", columns), ("lines", lines)] {
        if !spec.uniforms.iter().any(|(key, _)| key == name)
            && candidate
                .instance
                .get_func(&mut candidate.store, &format!("uniform_set_{name}"))
                .is_some()
        {
            apply_uniform(
                &candidate.instance,
                &mut candidate.store,
                &candidate.label,
                name,
                &value.to_string(),
            )?;
        }
    }
    for (name, value) in &spec.uniforms {
        apply_uniform(
            &candidate.instance,
            &mut candidate.store,
            &candidate.label,
            name,
            value,
        )?;
    }
    Ok(())
}

fn render_frame(
    stages: &mut [BenchCandidate],
    specs: &[StageSpec],
    initial: Option<&[u8]>,
) -> Result<(), String> {
    let mut output = Vec::new();
    for (index, (candidate, spec)) in stages.iter_mut().zip(specs).enumerate() {
        apply_dimensions(candidate, spec)?;
        output = candidate.render(if index == 0 {
            initial.unwrap_or(&[])
        } else {
            &output
        })?;
    }
    if !stages.last().is_some_and(|stage| stage.is_utf8) {
        return Err("TUI pipeline must produce UTF-8 output".into());
    }
    validate_frame(&output)?;
    let mut stdout = io::stdout().lock();
    stdout
        .write_all(b"\x1b[H\x1b[J")
        .map_err(|e| format!("cannot write terminal frame: {e}"))?;
    for (index, line) in output.split(|byte| *byte == b'\n').enumerate() {
        if index != 0 {
            stdout
                .write_all(b"\r\n")
                .map_err(|e| format!("cannot write terminal frame: {e}"))?;
        }
        stdout
            .write_all(line)
            .map_err(|e| format!("cannot write terminal frame: {e}"))?;
    }
    stdout
        .write_all(b"\x1b[0m\x1b[J")
        .map_err(|e| format!("cannot write terminal frame: {e}"))?;
    stdout
        .flush()
        .map_err(|e| format!("cannot flush terminal frame: {e}"))
}

fn validate_frame(bytes: &[u8]) -> Result<(), String> {
    let text = std::str::from_utf8(bytes).map_err(|e| {
        format!(
            "terminal output contains invalid UTF-8 at byte {}",
            e.valid_up_to()
        )
    })?;
    let mut chars = text.char_indices().peekable();
    while let Some((index, character)) = chars.next() {
        if character == '\x1b' {
            if chars.next().map(|(_, value)| value) != Some('[') {
                return Err(format!(
                    "terminal output contains unsupported ESC sequence at byte {index}"
                ));
            }
            let mut parameters = String::new();
            loop {
                match chars.next() {
                    Some((_, 'm')) => break,
                    Some((_, value)) if value.is_ascii_digit() || value == ';' => {
                        parameters.push(value)
                    }
                    Some(_) => {
                        return Err(format!(
                            "terminal output contains unsupported CSI sequence at byte {index}"
                        ));
                    }
                    None => {
                        return Err(format!(
                            "terminal output contains incomplete SGR sequence at byte {index}"
                        ));
                    }
                }
            }
            let parts = if parameters.is_empty() {
                vec!["0"]
            } else {
                parameters.split(';').collect::<Vec<_>>()
            };
            if parts.len() > 16
                || parts.iter().any(|part| {
                    let value = if part.is_empty() {
                        Some(0)
                    } else {
                        part.parse::<u16>().ok()
                    };
                    !matches!(
                        value,
                        Some(
                            0
                            | 1
                            | 2
                            | 4
                            | 22
                            | 24
                            | 30..=37
                            | 39
                            | 40..=47
                            | 49
                            | 90..=97
                            | 100..=107,
                        )
                    )
                })
            {
                return Err(format!(
                    "terminal output contains unsupported SGR parameters at byte {index}"
                ));
            }
            continue;
        }
        if character == '\n' {
            continue;
        }
        if character == '\x7f' {
            return Err(format!("terminal output contains DEL at byte {index}"));
        }
        if character.is_control() {
            return Err(format!(
                "terminal output contains control character at byte {index}"
            ));
        }
    }
    Ok(())
}

fn keysym(event: KeyEvent) -> Option<(i32, i32)> {
    let flags = (if event.modifiers.contains(KeyModifiers::SHIFT) {
        4
    } else {
        0
    }) | (if event.modifiers.contains(KeyModifiers::CONTROL) {
        8
    } else {
        0
    }) | (if event.modifiers.contains(KeyModifiers::ALT) {
        16
    } else {
        0
    });
    let key = match event.code {
        KeyCode::Char(value) => value as i32,
        KeyCode::Backspace => 0xff08,
        KeyCode::Tab | KeyCode::BackTab => 0xff09,
        KeyCode::Enter => 0xff0d,
        KeyCode::Esc => 0xff1b,
        KeyCode::Home => 0xff50,
        KeyCode::Left => 0xff51,
        KeyCode::Up => 0xff52,
        KeyCode::Right => 0xff53,
        KeyCode::Down => 0xff54,
        KeyCode::PageUp => 0xff55,
        KeyCode::PageDown => 0xff56,
        KeyCode::End => 0xff57,
        KeyCode::Insert => 0xff63,
        KeyCode::Delete => 0xffff,
        KeyCode::F(number @ 1..=12) => 0xffbe + number as i32 - 1,
        _ => return None,
    };
    Some((key, flags))
}

#[cfg(unix)]
fn suspend_terminal(stages: &mut [BenchCandidate], specs: &[StageSpec]) -> Result<(), String> {
    let _ = io::stdout().write_all(b"\x1b[0m");
    execute!(
        io::stdout(),
        terminal::LeaveAlternateScreen,
        crossterm::cursor::Show
    )
    .map_err(|e| format!("cannot leave alternate screen: {e}"))?;
    terminal::disable_raw_mode().map_err(|e| format!("cannot leave terminal raw mode: {e}"))?;
    // SIGTSTP is delivered only after the terminal has been restored.
    unsafe {
        libc::raise(libc::SIGTSTP);
    }
    terminal::enable_raw_mode().map_err(|e| format!("cannot enter terminal raw mode: {e}"))?;
    execute!(
        io::stdout(),
        terminal::EnterAlternateScreen,
        crossterm::cursor::Hide
    )
    .map_err(|e| format!("cannot enter alternate screen: {e}"))?;
    render_frame(stages, specs, None)
}

pub(super) fn run_tui(
    mut stages: Vec<BenchCandidate>,
    specs: &[StageSpec],
    input: Vec<u8>,
) -> Result<(), String> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err("qipx tui requires terminal stdin and stdout".into());
    }
    if stages.is_empty() {
        return Err("at least one component is required".into());
    }
    let first = &mut stages[0];
    first
        .instance
        .get_typed_func::<i64, ()>(&mut first.store, "begin_update_at")
        .map_err(|_| format!("{} must export begin_update_at(i64)", first.label))?;
    first
        .instance
        .get_typed_func::<(i32, i32), i32>(&mut first.store, "key_event")
        .map_err(|_| format!("{} must export key_event(i32, i32) -> i32", first.label))?;
    first
        .instance
        .get_typed_func::<(), i64>(&mut first.store, "finish_update")
        .map_err(|_| format!("{} must export finish_update() -> i64", first.label))?;
    for stage in stages.iter_mut().skip(1) {
        if stage
            .instance
            .get_func(&mut stage.store, "begin_update_at")
            .is_some()
            || stage
                .instance
                .get_func(&mut stage.store, "finish_update")
                .is_some()
        {
            return Err(format!(
                "{} must be a Content component when used after a TUI component",
                stage.label
            ));
        }
    }
    if !stages.last().is_some_and(|stage| stage.is_utf8) {
        return Err("TUI pipeline must produce UTF-8 output".into());
    }
    #[cfg(unix)]
    let signals = {
        let signals = [libc::SIGINT, libc::SIGTERM, libc::SIGHUP].map(|signal| {
            let flag = Arc::new(AtomicBool::new(false));
            signal_hook::flag::register(signal, Arc::clone(&flag))
                .map_err(|e| format!("cannot register terminal signal handler: {e}"))?;
            Ok::<_, String>((signal, flag))
        });
        signals.into_iter().collect::<Result<Vec<_>, _>>()?
    };
    terminal::enable_raw_mode().map_err(|e| format!("cannot enter terminal raw mode: {e}"))?;
    let guard = TerminalGuard;
    execute!(
        io::stdout(),
        terminal::EnterAlternateScreen,
        crossterm::cursor::Hide
    )
    .map_err(|e| format!("cannot enter alternate screen: {e}"))?;
    let started = Instant::now();
    render_frame(&mut stages, specs, Some(&input))?;
    let mut last = started.elapsed().as_millis().min(i64::MAX as u128) as i64 + 1;
    let first = &mut stages[0];
    first
        .instance
        .get_typed_func::<i64, ()>(&mut first.store, "begin_update_at")
        .map_err(|e| e.to_string())?
        .call(&mut first.store, last)
        .map_err(|e| format!("{} begin_update_at trapped: {e}", first.label))?;
    apply_dimensions(first, &specs[0])?;
    let mut next_wake = first
        .instance
        .get_typed_func::<(), i64>(&mut first.store, "finish_update")
        .map_err(|e| e.to_string())?
        .call(&mut first.store, ())
        .map_err(|e| format!("{} finish_update trapped: {e}", first.label))?;
    if next_wake < last {
        return Err(format!("{} returned an invalid wake time", first.label));
    }
    loop {
        #[cfg(unix)]
        for (signal, flag) in &signals {
            if flag.load(Ordering::Relaxed) {
                drop(guard);
                std::process::exit(128 + signal);
            }
        }
        let elapsed = started.elapsed().as_millis().min(i64::MAX as u128) as i64 + 1;
        let wait = if next_wake > last {
            Duration::from_millis((next_wake - elapsed).max(0) as u64)
        } else {
            Duration::from_secs(3600)
        }
        .min(Duration::from_millis(100));
        let ready = event::poll(wait).map_err(|e| format!("cannot poll terminal events: {e}"))?;
        let mut key = None;
        let mut redraw = false;
        if ready {
            match event::read().map_err(|e| format!("cannot read terminal event: {e}"))? {
                Event::Key(event) if event.kind != KeyEventKind::Release => {
                    if event.modifiers.contains(KeyModifiers::CONTROL) {
                        if matches!(event.code, KeyCode::Char('c') | KeyCode::Char('C')) {
                            break;
                        }
                        #[cfg(unix)]
                        if matches!(event.code, KeyCode::Char('z') | KeyCode::Char('Z')) {
                            suspend_terminal(&mut stages, specs)?;
                            continue;
                        }
                        if matches!(
                            event.code,
                            KeyCode::Char('s')
                                | KeyCode::Char('S')
                                | KeyCode::Char('q')
                                | KeyCode::Char('Q')
                        ) {
                            continue;
                        }
                    }
                    key = keysym(event);
                }
                Event::Resize(_, _) => {
                    redraw = true;
                }
                _ => continue,
            }
        } else if next_wake > last && elapsed >= next_wake {
            redraw = true;
        }
        if key.is_none() && !redraw {
            continue;
        }
        let now = elapsed
            .max(last + 1)
            .max(if !ready { next_wake } else { 0 });
        let first = &mut stages[0];
        first
            .instance
            .get_typed_func::<i64, ()>(&mut first.store, "begin_update_at")
            .map_err(|e| e.to_string())?
            .call(&mut first.store, now)
            .map_err(|e| format!("{} begin_update_at trapped: {e}", first.label))?;
        apply_dimensions(first, &specs[0])?;
        if let Some((keysym, flags)) = key {
            let function = first
                .instance
                .get_typed_func::<(i32, i32), i32>(&mut first.store, "key_event")
                .map_err(|e| e.to_string())?;
            let down = function
                .call(&mut first.store, (keysym, flags | 1))
                .map_err(|e| format!("{} key_event trapped: {e}", first.label))?;
            let up = function
                .call(&mut first.store, (keysym, flags))
                .map_err(|e| format!("{} key_event trapped: {e}", first.label))?;
            redraw |= down == 1 || up == 1;
        }
        next_wake = first
            .instance
            .get_typed_func::<(), i64>(&mut first.store, "finish_update")
            .map_err(|e| e.to_string())?
            .call(&mut first.store, ())
            .map_err(|e| format!("{} finish_update trapped: {e}", first.label))?;
        if next_wake < now {
            return Err(format!("{} returned an invalid wake time", first.label));
        }
        last = now;
        if redraw {
            render_frame(&mut stages, specs, None)?;
        }
    }
    Ok(())
}
