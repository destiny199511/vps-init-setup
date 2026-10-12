# VPS Configuración con Un Clic

[![Shell](https://img.shields.io/badge/shell-bash-grey)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

[English](README.en.md) | [中文](README.md) | [日本語](README.ja.md) | **Español**

Un script de inicialización y refuerzo de seguridad para VPS Linux. Configura usuarios, SSH, firewall, Docker, copias de seguridad, monitorización y optimización del sistema a través de un asistente interactivo o un archivo de configuración.

## Primeros Pasos

### Inicio Rápido (Recomendado)

Ejecuta como `root` o con `sudo` en un VPS Linux nuevo:

```bash
# 1. Clonar el repositorio
git clone https://github.com/destiny199511/vps-init-setup.git
cd vps-init-setup

# 2. Iniciar el asistente interactivo
sudo ./vps_setup.sh
```

### Instalación Segura para Producción (Verificación de Release)

Para entornos de producción, instala usando un commit Git inmutable y sumas de verificación SHA-256 independientes:

```bash
export VPS_COMMIT="<40-hex-commit>"
export ARCHIVE_SHA256="<release-archive-sha256>"
export INSTALLER_SHA256="<release-installer-sha256>"

# Descargar y verificar el instalador
curl -fsSLo install.sh "https://raw.githubusercontent.com/destiny199511/vps-init-setup/${VPS_COMMIT}/install.sh"
printf '%s  %s\n' "$INSTALLER_SHA256" install.sh | sha256sum -c -

# Verificar archivo fuente e instalar en /opt/vps-init-setup
sudo bash install.sh --ref "$VPS_COMMIT" --sha256 "$ARCHIVE_SHA256"
```

> 💡 **Verificación de Release**: Cada Release incluye `source-commit.txt`, manifiestos SHA-256 y atestados de procedencia de GitHub (verificables mediante `gh attestation verify`).
> ⚠️ **Prevención de Bloqueo**: Mantén abierta tu sesión SSH actual antes de cambiar puertos o reglas del firewall. Comprueba la conexión en una nueva terminal antes de desconectar.

## Configuración

Entra en el directorio del proyecto:

```bash
cd /opt/vps-init-setup
```

### Asistente Interactivo

```bash
sudo ./vps_setup.sh
```

El menú principal ofrece:

1. Asistente completo: recopila en orden la configuración de sistema, usuario, limpieza, SSH, seguridad, servicios, copias de seguridad y monitorización.
2. Configuración por secciones: ajusta una sola categoría de configuración.
3. Vista previa de la configuración: revisa los parámetros que se aplicarán.
4. Cargar o restablecer un archivo de configuración.
5. Iniciar la instalación.
6. Ver el estado de los módulos.
7. Ver el informe de salud más reciente.

En el asistente, pulsa `Enter` para usar los valores predeterminados; pulsa `b` o `Esc` para volver al paso anterior. Se admiten las teclas de flecha, `j`/`k` y las teclas numéricas para la selección del menú. Se usa una interfaz de tarjetas cuando el terminal tiene al menos 60 columnas y es un TTY; en caso contrario, vuelve automáticamente a un menú de texto.

### Ejecución Desatendida y Simulación

```bash
# Crear un archivo de configuración local a partir del ejemplo
sudo install -m 600 examples/example_user_config.conf config/vps_config.conf

# Previsualizar los cambios sin modificar el sistema
sudo ./vps_setup.sh -n -d

# Ejecutar la instalación usando el archivo de configuración o los valores predeterminados
sudo ./vps_setup.sh -n

# Modo automático: no interactivo y omite la confirmación
sudo ./vps_setup.sh -a

# Ejecutar solo módulos específicos
sudo ./vps_setup.sh -n --modules 05_ssh,06_firewall

# Forzar la reejecución de módulos completados
sudo ./vps_setup.sh -n -f
```

## Verificación del Estado del VPS

Después de que la configuración termine, consulta primero el informe de salud:

```bash
sudo ./vps_setup.sh --health
```

El informe compara la configuración objetivo con el estado actual del sistema y muestra los recuentos de éxito/advertencia/fallo; los archivos se guardan en `logs/health_report_*.txt`.

Otras comprobaciones útiles:

```bash
# Si los módulos se completaron, se omitieron o fallaron
sudo ./vps_setup.sh --status

# Comando de inicio de sesión SSH y resultados clave de la ejecución
cat config/install-result.env

# Registro de esta ejecución
tail -f logs/vps_setup_*.log
```

Al final de cada ejecución también se muestra una tarjeta de estado en vivo, que incluye nombre de host, zona horaria, idioma, puerto SSH, firewall, swap, Docker y Fail2ban.

## Alcance de Funciones

| Categoría | Módulos | Contenido |
|---|---|---|
| Comprobaciones previas y base | `00`-`03` | Permisos, recursos del sistema, nombre de host, zona horaria, idioma y DNS |
| Seguridad de acceso | `04`-`07` | Usuario administrador no root, refuerzo de SSH, firewall, Fail2ban |
| Servicios y red | `08`-`09` | Docker, BBR y parámetros del kernel TCP |
| Operaciones | `10`-`12` | Copias de seguridad automáticas, herramientas de monitorización, auditoría y análisis de seguridad |
| Limpieza y optimización | `13` | Swap, Snap, caché, journal y limpieza de servicios no utilizados |

## Opciones Comunes

```text
-n, --non-interactive   Usa el archivo de configuración o los valores predeterminados; no entra en el menú interactivo
-a, --auto              Modo no interactivo y omite la confirmación
-d, --dry-run           Simulación; no modifica el sistema
-f, --force             Fuerza la reejecución de módulos completados
--modules <list>        Ejecuta solo los módulos especificados, p. ej. 01_hostname,05_ssh
--status                Muestra el estado de ejecución de los módulos
--health                Muestra el informe de salud de configuración más reciente
--view, --show-config   Inspecciona la configuración común del sistema (secciones: all, user, ssh, firewall, docker, backup, monitoring, optimization)
--set-password [user]   Configura o modifica la contraseña de usuario para sistema y sudo (alias: --passwd)
```

Para la lista completa de opciones, ejecuta:

```bash
sudo ./vps_setup.sh --help
```

## Actualizaciones y Ubicación de Archivos

Las actualizaciones usan el mismo commit fijado y los SHA-256 verificados de forma independiente:

```bash
sudo bash install.sh --ref "$VPS_COMMIT" --sha256 "$ARCHIVE_SHA256" --update-only
```

Parámetros comunes de `install.sh`:
- `--ref <commit-hex-de-40>`: Especifica un commit Git inmutable de 40 caracteres (obligatorio para instalaciones remotas).
- `--sha256 <hash>`: SHA-256 esperado del archivo fuente de ese commit (obligatorio para instalaciones remotas).
- `--update-only`: Actualiza los archivos sin iniciar el asistente de configuración.

Las actualizaciones conservan `config/`, `logs/` y `backups/`. Archivos clave:

- Configuración: `config/vps_config.conf`
- Resultados de ejecución: `config/install-result.env`
- Registros de ejecución: `logs/vps_setup_*.log`
- Registros de auditoría de seguridad: `logs/audit_*.log`
- Copias de seguridad automáticas e instantáneas de configuración: `backups/`

> `--rollback` permite restaurar automáticamente los archivos de configuración del sistema modificados; las cuentas de usuario y paquetes se pueden gestionar con los snapshots en `backups/` y los registros de auditoría.

## Solución de Problemas y Verificación

- **Instalacion de produccion y prevencion de manipulacion**: Las ramas mutables y la omision de verificacion no estan permitidas. Obtenga el commit y ambos SHA-256 de un registro de release verificado de forma independiente y siga el flujo de verificacion inicial.

## Compatibilidad

Dirigido principalmente a distribuciones VPS comunes como Ubuntu, Debian, CentOS Stream, Rocky Linux y AlmaLinux. Las máquinas nuevas pueden tener actualizaciones en segundo plano que mantienen el bloqueo de APT; el script espera automáticamente, hasta 300 segundos por defecto. Ajusta con `APT_LOCK_WAIT=600`.

## Licencia

[MIT License](LICENSE)
