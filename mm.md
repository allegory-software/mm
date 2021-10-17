# Many Machines

Many Machines is a DevOp platform with a web UI. MM lets you add remote
machines to a database and then run custom bash scripts on them and
monitor/see the output of those scrips in real-time. It also lets you create
deployments which you can then install on specific machines, move them
from one machine to another, perform automatic updates, etc.

## Downloading

```
mgit clone https://github.com/allegory-software/mm
cd mm
mgit clone-all
```

## Prerequisite files

```
home.key            ssh private key that gives root access to any machine
home.key.pub        ssh public key of home.key
mm-github.key       github private key that allows pushing to github (optional)
```

## Installation

```
mm install          create a new database (needs MySQL)
```

# Usage

```
mm start            start the web server
```
