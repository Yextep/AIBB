# AIBB — Auto Bounty

Instalador Bash de herramientas utilizadas en reconocimiento y pruebas de seguridad. [`install.sh`](install.sh) prepara dependencias, instala herramientas desde distintos gestores y repositorios, y comprueba los comandos disponibles al finalizar.

## Qué incluye

- Detección de plataformas con `apt`, `dnf`, `pacman`, `apk`, Homebrew o el gestor `pkg` de Termux.
- Instalación de dependencias de compilación y entornos de Python, Go, Rust y Ruby según la plataforma.
- Instalación de herramientas mediante Go, releases de GitHub, Cargo, RubyGems, pipx y repositorios Python con entornos virtuales.
- Reintentos, registro por ejecución y un resumen de pasos completados, advertencias y fallos.
- Configuración de rutas de herramientas, patrones de `gf` y actualización de plantillas de Nuclei.
- Verificación de comandos mediante opciones de ayuda o versión.

### Herramientas contempladas

La instalación efectiva depende del sistema, la arquitectura y la disponibilidad de los proyectos externos.

| Área | Ejemplos incluidos en el script |
| --- | --- |
| Subdominios y DNS | `subfinder`, `amass`, `findomain`, `dnsx`, `assetfinder`, `github-subdomains` |
| URLs y navegación | `gau`, `urlfinder`, `hakrawler`, `katana`, `uro` |
| HTTP y capturas | `httpx`, alias `httpx-toolkit`, `aquatone` |
| Puertos y red | `nmap`, `masscan`, `naabu`, `asnmap` |
| Comprobaciones web | `nuclei`, `ffuf`, `dirsearch`, `arjun`, `wpscan`, `subzy` |
| CORS y parámetros | `CORScanner`, `Corsy`, `qsreplace`, `gf` |
| Pruebas relacionadas con XSS | `dalfox`, `bxss`, `Gxss` |

## Requisitos

- Bash y acceso a Internet para la instalación.
- Un gestor de paquetes contemplado por el script, o las dependencias ya instaladas.
- Root o `sudo` para las operaciones del gestor del sistema que lo requieran. Termux y Homebrew tienen sus propias rutas de instalación.
- Espacio para repositorios, entornos virtuales y binarios.

La existencia de una ruta de instalación para una plataforma no garantiza que todas las herramientas externas puedan instalarse en ella.

## Uso

Desde la carpeta del repositorio:

```bash
# Consultar la ayuda
bash install.sh --help

# Ejecutar la instalación
bash install.sh

# Instalar las herramientas usando dependencias del sistema ya preparadas
bash install.sh --skip-system

# Seleccionar directorios propios
bash install.sh --bin-dir "$HOME/.local/bin" --tools-dir "$HOME/.auto-bounty/tools"

# Comprobar los comandos de una instalación existente
bash install.sh --verify-only
```

## Opciones

| Opción | Comportamiento |
| --- | --- |
| `--verify-only` | Omite la instalación de herramientas y ejecuta la verificación final. |
| `--skip-system` | Omite la instalación de paquetes del sistema. |
| `--bin-dir DIR` | Cambia el destino de los binarios y comandos generados. |
| `--tools-dir DIR` | Cambia el destino de los repositorios de herramientas. |
| `--no-git-pull` | Evita actualizar los repositorios ya clonados. |
| `--with-browser` | Solicita Chromium en las rutas de paquetes que contemplan esa opción. |
| `-h`, `--help` | Muestra la ayuda. |

## Directorios y entorno

| Variable | Valor predeterminado |
| --- | --- |
| `AUTO_BOUNTY_HOME` | `$HOME/.auto-bounty` |
| `AUTO_BOUNTY_TOOLS` | `$AUTO_BOUNTY_HOME/tools` |
| `AUTO_BOUNTY_BIN` | `/usr/local/bin` si se ejecuta como root y el directorio es escribible; en otro caso, `$HOME/.local/bin` |

El script guarda logs en `$AUTO_BOUNTY_HOME/logs` y genera `$AUTO_BOUNTY_HOME/env` con las rutas del entorno. Si existe `$HOME/.bashrc` y aún no carga ese archivo, añade una instrucción para cargarlo. Al finalizar, indica el comando `source` correspondiente.

`--verify-only` también inicializa directorios, logs y el archivo de entorno. La verificación puede crear alias y tratar de ajustar las capacidades de red de `masscan` y `naabu`; no equivale a una ejecución sin escrituras.

## Resultados y límites

Un comando detectado y verificado puede conservarse sin reinstalación. El script incluye la variable `AUTO_BOUNTY_FORCE_UPDATE=1` para forzar los pasos de actualización que la consultan. Las herramientas se obtienen de fuentes externas y varias rutas usan versiones recientes, sin un conjunto de versiones fijado.

Si hay pasos o comprobaciones fallidas, el resumen enumera los problemas y el proceso termina con código `1`. Consulta el log indicado antes de repetir la instalación. Una comprobación de ayuda o versión confirma que el comando responde, sin certificar todas sus funciones.

El instalador recuerda que las herramientas deben usarse únicamente sobre activos para los que exista autorización explícita.
