//! Tail regular log files so inherited output handles cannot delay worker completion.
use super::Event;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read},
    path::Path,
    process::{Command, Stdio},
    sync::mpsc::Sender,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
struct Tail {
    file: File,
    pending: Vec<u8>,
}
impl Tail {
    fn open(path: &Path) -> io::Result<Self> {
        Ok(Self { file: File::open(path)?, pending: Vec::new() })
    }
    fn poll(&mut self, tx: &Sender<Event>, finish: bool) -> io::Result<()> {
        let mut buffer = [0_u8; 8192];
        // Bound work per tick, memory per line, and avoid decoding incomplete UTF-8 fragments.
        for _ in 0..128 {
            let count = self.file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            for byte in buffer.get(..count).unwrap_or_default() {
                if *byte == b'\n' {
                    self.emit(tx);
                } else {
                    self.pending.push(*byte);
                    if self.pending.len() >= 65536 {
                        self.emit(tx);
                    }
                }
            }
        }
        if finish && !self.pending.is_empty() {
            self.emit(tx);
        }
        Ok(())
    }
    fn emit(&mut self, tx: &Sender<Event>) {
        let line = String::from_utf8_lossy(&self.pending).trim_end_matches('\r').to_owned();
        self.pending.clear();
        let _ = tx.send(Event::Log(line));
    }
}
pub fn run(mut command: Command, root: &Path, tx: &Sender<Event>) -> io::Result<bool> {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|v| v.as_nanos()).unwrap_or(0);
    let directory = root.join(format!(".local-ai/mangacolorai/worker-logs/{}-{stamp}", std::process::id()));
    fs::create_dir_all(&directory)?;
    let stdout = directory.join("stdout.log");
    let stderr = directory.join("stderr.log");
    let output = OpenOptions::new().create_new(true).write(true).open(&stdout)?;
    let errors = OpenOptions::new().create_new(true).write(true).open(&stderr)?;
    command.stdin(Stdio::null()).stdout(Stdio::from(output)).stderr(Stdio::from(errors));
    let mut child = command.spawn()?;
    let mut out = Tail::open(&stdout)?;
    let mut err = Tail::open(&stderr)?;
    loop {
        out.poll(tx, false)?;
        err.poll(tx, false)?;
        if let Some(status) = child.try_wait()? {
            out.poll(tx, true)?;
            err.poll(tx, true)?;
            return Ok(status.success());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[test]
    fn open_writer_does_not_block_completion_and_utf8_survives_chunks() -> io::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|v| v.as_nanos()).unwrap_or(0);
        let path = std::env::temp_dir().join(format!("mangacolorai-log-{}-{stamp}", std::process::id()));
        let mut writer = OpenOptions::new().write(true).create_new(true).open(&path)?;
        let mut tail = Tail::open(&path)?;
        let (tx, rx) = std::sync::mpsc::channel();
        writer.write_all(&[0xE6, 0xBC])?;
        tail.poll(&tx, false)?;
        assert!(rx.try_recv().is_err());
        writer.write_all(&[0xA2, b'\n'])?;
        tail.poll(&tx, false)?;
        assert!(matches!(rx.try_recv(),Ok(Event::Log(line)) if line=="漢"));
        writer.write_all(b"[RESULT] image.png\nlast message")?;
        let start = std::time::Instant::now();
        tail.poll(&tx, true)?;
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(matches!(rx.try_recv(),Ok(Event::Log(line)) if line=="[RESULT] image.png"));
        assert!(matches!(rx.try_recv(),Ok(Event::Log(line)) if line=="last message"));
        drop(tail);
        drop(writer);
        fs::remove_file(path)?;
        Ok(())
    }
    #[test]
    fn worker_exit_completes_with_an_inherited_log_handle() -> io::Result<()> {
        if !cfg!(windows) {
            return Ok(());
        }
        let root = std::env::temp_dir().join(format!("mangacolorai-worker-test-{}", std::process::id()));
        let (tx, rx) = std::sync::mpsc::channel();
        let mut command = Command::new("powershell.exe");
        // Synthetic background sleeper holds inherited streams; never starts a model.
        command.args(["-NoProfile","-Command","$p=[Diagnostics.ProcessStartInfo]::new();$p.FileName='ping.exe';$p.Arguments='-n 5 127.0.0.1';$p.UseShellExecute=$false;$p.CreateNoWindow=$true;$null=[Diagnostics.Process]::Start($p);Write-Output '[RESULT] fixture.png'"]);
        let start = std::time::Instant::now();
        assert!(run(command, &root, &tx)?);
        assert!(start.elapsed() < Duration::from_secs(3));
        assert!(rx.try_iter().any(|e| matches!(e,Event::Log(line) if line=="[RESULT] fixture.png")));
        Ok(())
    }
}
