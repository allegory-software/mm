# Many Machines

Many Machines is a SAAS provisioning and administration tool with
a web UI, a command-line UI and a HTTP API.

MM keeps a database of your machines and deployments and provides you with
a UI from which to perform and automate all your sysadmin tasks like SSH key
management, scheduled backups, automated deployments, SSL certificate issuing,
real-time app monitoring, etc.

One notable feature of MM that's less common in tools of this type is the
presence of Windows-native sysadmin tools like sshfs, putty, etc.

A terse but more extensive list of features and limitations is currently
[in the code](https://github.com/allegory-software/many-machines/blob/master/mm.lua).

## Installing

```
git clone git@github.com:allegory-software/mm
git clone git@github.com:allegory-software/allegory-sdk mm/sdk
git clone git@github.com:allegory-software/allegory-sdk-bin-debian10  mm/sdk/bin/linux
git clone git@github.com:allegory-software/allegory-sdk-bin-windows   mm/sdk/bin/windows
```

#### On a dev machine use the `dev` branch of the sdk...

```
(cd mm/sdk && git checkout dev)
(cd mm/sdk/bin/linux && git checkout dev)
```

## Configuring

MM can run in different ways:

* as a server, with a web UI and HTTP API.
* as a client, forwarding commands to a server (command-line only).
* offline, operating on a local mm database directly (command-line only).

By default it is configured to run as a client to `mm.allegory.ro` which
is Allegory's production server. All you need is to add `session_cookie`
to `mm.conf`, which you can get from your browser after you login
at `https://mm.allegory.ro`.

For other scenarios, add to `mm.conf`:

```
--server or offline: MySQL access to the mm database.
db_host = '...' --mysql server host or IP, if not 127.0.0.1
db_port =  ...  --if not 3306
db_user = '...' --if not root
db_pass = '...' --required

--server: SMTP access for sending one-time passwords on web login.
smtp_host = '...' --smtp server host or IP, if not 127.0.0.1
smtp_user = '...' --if SMTP auth required
smtp_pass = '...' --required if smtp_user given
smtp_port = 25    --if different than 465 or 587
smtp_tls  = false --if the server does not support TLS
noreply_email = '...' --OTP sender email (one that your SMTP server accepts!).

--server: on a dev machine without a SSL certificate do this:
http_port  = 8080
https_addr = false
session_cookie_secure_flag = false
dev_email  = '...' --your email (required!): a user will be created automatically for it.
secret     = '...' --random secret string (required for a production server!).

--server: self-monitoring (register the mm server as a deploy to monitor it).
deploy = '...'    -- deploy name
log_host = '127.0.0.1'  --yes, mm will make a SSH reverse tunnel for it.
log_port = 5555   --required

--client: access to a remote mm instance.
mm_host = '...'
session_cookie = '...' --take it from the browser after you login.

--if the remote mm instance is an insecure dev machine, also add:
mm_port = 8080    --the http_port you put on the mm server config.
mm_https = false

--cmdline offline mode (no mm server running):
mm_host = false

deploy = '...' --name this mm deployment.
```

## Using

```
$ ./mm      # on Linux
> mm        # on Windows
```

## System Requirements

Debian 10 or Windows 10
A SMTP server (for web login)
MySQL 8 (for now)
Tarantool 2.10 (in the future)

## Adding machines

Any machine you add has to be preconfigured to allow SSH root access using
the public key derived from `var/mm.key`. For that you need to put the
contents of the SSH public key, which you can get by typing `mm ssh-pubkey`,
in the machine's `/root/.ssh/authorized_keys` (don't forget to chmod the
file to `0600` if you had to create it). After you add a machine you need
to update it's SSH fingerprint and then _prepare it_ (right-click on the
machine in the machines grid to see these commands or use the command-line).
