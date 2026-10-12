#[tokio::main]
async fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [] => pirc_server::run().await,
        [command, code] if command == "allow" => {
            if let Err(error) = pirc_server::allow(code).await {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        _ => {
            eprintln!("Help: pirc-server [allow XXXX-XXXX]");
            std::process::exit(1);
        }
    }
}
