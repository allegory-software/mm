# Many Machines

Many Machines is a SAAS provisioning and administration tool with
a web and command-line UI.

MM keeps a database of your machines and deployments and provides you with
a shell from which to do all your tedious sysadmin tasks, from SSH key
management and backups to automated deployments and upgrades, app monitoring
and database cluster configuration.

## Downloading

```
mgit clone https://github.com/allegory-software/mm
cd mm
mgit clone-all
```

## Dependencies

Tarantool 2.8.

## Configuration

I'll write it when it's stable.

## Installation

I'll write it when it's stable.

## Adding machines

Any machine you add must be preconfigured to allow SSH root access using
`mm-var/mm.key`. For that you need to put the contents of the SSH public
key (which you can get by typing `mm ssh-pubkey`) in the machine's
`/root/.ssh/authorized_keys` (don't forget to chmod the file to `0600`
if you had to create it).
