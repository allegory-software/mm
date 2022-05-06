# Many Machines

Many Machines is a SAAS provisioning and administration tool with
a web and command-line UI.

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
git clone https://github.com/allegory-software/mm
git clone https://github.com/allegory-software/allegory-sdk mm/sdk
git clone git@github.com:allegory-software/allegory-sdk-bin-debian10  mm/sdk/bin/linux
git clone git@github.com:allegory-software/allegory-sdk-bin-windows   mm/sdk/bin/windows
```

## Using

```
$ ./mm
> mm
```

## Dependencies

MySQL 8 (for now)
Tarantool 2.8 (in the future)

## Configuration

I'll write it when it's stable.

## Adding machines

Any machine you add must be preconfigured to allow SSH root access using
`var/mm.key`. For that you need to put the contents of the SSH public
key (which you can get by typing `mm ssh-pubkey`) in the machine's
`/root/.ssh/authorized_keys` (don't forget to chmod the file to `0600`
if you had to create it).
