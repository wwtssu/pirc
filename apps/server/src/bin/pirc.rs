const USAGE: &str = "Help:\n  pirc server [--port PORT]  Start the server\n  pirc waitlist             List pending connections\n  pirc allow XXXX-XXXX      Authorize a client";
const SERVER_HELP: &str = "Help: pirc server [--port PORT]\n\nRuns in the foreground. Press Ctrl+C to stop.\n--port PORT sets the listening port (1-65535).\nDefault port: 43123.";

fn server_port(args: &[String]) -> Result<Option<u16>, String> {
    let value = match args {
        [] => return Ok(None),
        [flag, value] if flag == "--port" => value.as_str(),
        [flag] if flag.starts_with("--port=") => &flag[7..],
        _ => return Err(SERVER_HELP.into()),
    };
    value
        .parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .map(Some)
        .ok_or_else(|| "Invalid port. Expected an integer from 1 to 65535.".into())
}
#[tokio::main]
async fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [command, flags @ ..] if command == "server" => {
            if matches!(flags, [flag] if flag == "--help" || flag == "-h") {
                println!("{SERVER_HELP}");
                Ok(())
            } else {
                match server_port(flags) {
                    Ok(port) => {
                        pirc_server::run_with_port(port).await;
                        Ok(())
                    }
                    Err(error) => Err(error),
                }
            }
        }
        [command] if command == "waitlist" => pirc_server::waitlist().await,
        [command, code] if command == "allow" => pirc_server::allow(code).await,
        [] => {
            println!("{USAGE}");
            Ok(())
        }
        [command] if command == "--help" || command == "-h" || command == "help" => {
            println!("{USAGE}");
            Ok(())
        }
        _ => Err(USAGE.into()),
    };
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::server_port;
    #[test]
    fn port_options_require_a_valid_port_and_reject_extra_flags() {
        assert_eq!(server_port(&[]).unwrap(), None);
        for args in [vec!["--port", "43124"], vec!["--port=43124"]] {
            assert_eq!(
                server_port(&args.into_iter().map(String::from).collect::<Vec<_>>()).unwrap(),
                Some(43124)
            );
        }
        for args in [
            vec!["--port"],
            vec!["--port", "0"],
            vec!["--port", "65536"],
            vec!["--port=abc"],
            vec!["--port="],
            vec!["--port", "43124", "--port", "43125"],
            vec!["--other"],
        ] {
            assert!(server_port(&args.into_iter().map(String::from).collect::<Vec<_>>()).is_err());
        }
    }
}
