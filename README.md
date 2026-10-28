# raybus

Un log retenido con offsets y grupos de consumidores, escrito en [raylang](https://github.com/ray-language/raylang).
Varios servicios leen el mismo hecho, cada uno a su ritmo y desde donde quiera: rayq entrega un
trabajo a un consumidor y lo borra con el ack; raybus guarda el registro, y cada grupo apunta por
dónde va. Topics con particiones, la clave elige la partición, retención por tiempo y tamaño,
compactación por clave, y un grupo que reparte las particiones entre sus miembros y rebalancea
cuando uno entra o se va.

```
$ raybus serve
raybus 0.1.0: http://127.0.0.1:9500, data in data, retention 168 h, segments of 64 MiB, group sessions of 10000 ms

$ raybus create orders --partitions 2
$ printf 'alice\tpaid 10\nbob\tpaid 20\nalice\trefund 5\n' | raybus produce orders --tab
raybus: 3 record(s) to orders
$ raybus consume orders --group billing
orders/0@0	bob	paid 20
orders/1@0	alice	paid 10
orders/1@1	alice	refund 5
```

```
raybus serve [--config raybus.toml]
raybus create TOPIC [--partitions N] [--compact]
raybus produce TOPIC [--key K] [--tab]          una línea de stdin por registro
raybus consume TOPIC... --group G [--member ID]
raybus tail TOPIC [--partition P] [--from earliest|latest|N]
raybus topics | group G
raybus bench TOPIC [-n RECORDS] [-c CLIENTS] [-b RECORDS_PER_REQUEST] [--size BYTES]
```

## Estado

| Qué | Estado |
|---|---|
| Topics con particiones; la clave elige la partición (FNV-1a), sin clave se reparten | ✅ |
| Producir: cada petición se contesta cuando sus registros están sincronizados (commit agrupado por partición) | ✅ |
| Leer desde cualquier offset (`earliest`, `latest`, N), con espera (`wait`) hasta que llegue algo | ✅ |
| Segmentos que rotan por tamaño, índice disperso, CRC-32 por registro | ✅ |
| Recuperación: una cola a medio escribir del último segmento se corta; un segmento cerrado corrupto no arranca | ✅ |
| Retención por tiempo y tamaño (segmentos cerrados enteros) | ✅ |
| Compactación por clave (queda la última versión; las lápidas, valor vacío, se van con el tiempo; los offsets no cambian) | ✅ |
| Grupos: unirse, latido, salir, commit; generaciones y reparto; sesión que caduca; commits viejos rechazados | ✅ |
| Offsets de los grupos en un log propio, sincronizado, reescrito cuando crece | ✅ |
| Bloqueo del directorio (un segundo raybus en él no arranca) y token bearer | ✅ |
| Valores binarios (`value_b64`) | ✅ |
| Réplicas, transacciones, exactamente una vez | ➖ v2 |

Pruebas: 6 tests (`make test`, `make test-native`), en VM y nativo. Y dos comprobaciones contra el
binario:

- **`make crash`**: un productor en Python, de fuera, anota cada registro que raybus confirmó.
  raybus muere con `kill -9` a mitad de producir y vuelve a arrancar. Todo lo confirmado tiene que
  estar en su partición y su offset, y los offsets de cada partición tienen que seguir sin huecos ni
  repeticiones. Tres rondas: 903 200 confirmados, 0 perdidos, 0 cambiados (unos cientos de más:
  escritos y sincronizados, pero muertos antes de contestar).
- **La prueba de punta a punta**: dos consumidores de un grupo, uno se va a mitad. Cada registro llega
  al menos una vez, y dentro de una partición nunca se salta hacia delante.

## Cómo

```
src/main.ray       la línea de órdenes
src/config.ray     raybus.toml
src/server.ray     todo junto, con el bloqueo del directorio
src/api.ray        el API (JSON)
src/topics.ray     los topics: su configuración y una fibra por partición
src/partition.ray  una partición: segmentos, commit agrupado, índice, esperas, retención, compactación
src/codec.ray      un registro en disco (longitud, CRC-32, offset, hora, clave, valor)
src/groups.ray     el coordinador de grupos
src/client.ray     el cliente: producir, leer, y un consumidor de grupo
```

- **Una fibra por partición escribe**, con el commit agrupado de rayobs: toma lo que se ha acumulado
  mientras duraba la sincronización anterior, escribe una vez, sincroniza (`fs.sync_data`) y contesta
  a todos. Una petición que toca varias particiones les escribe en paralelo.
- **Las lecturas no pasan por esa fibra.** Le preguntan dónde está un offset (segmento y posición, por
  el índice disperso: una entrada cada 32 registros) y leen el archivo en su propia fibra. Lo
  confirmado ya está sincronizado, así que se ve.
- **Un registro lleva su CRC-32** (`inflate.crc32`). Al arrancar se leen todos los segmentos. Si la
  cola del último no cuadra (CRC, longitud, un registro cortado), se corta y se avisa; en un segmento
  cerrado es un error.
- **La compactación** reescribe los segmentos cerrados: se queda con el último registro de cada clave
  del log entero, y con los que no tienen clave. Escribe a un temporal, hace `fs.sync` y lo renombra.
  Los offsets no cambian, el log queda con huecos, y las lecturas los saltan.
- **Un grupo** reparte las particiones de cada topic entre sus miembros, ordenados por id. Cualquier
  cambio de miembros abre una generación nueva. Un latido con la generación vieja contesta
  `rebalance`, y el commit solo se acepta del miembro que tiene la partición en la generación actual.
  El consumidor confirma después de entregar: al menos una vez.

## Rendimiento

`make bench` (scripts/bench.sh): binario nativo con raylang 1.27.85 en un MacBook (Apple Silicon),
topics de 8 particiones, registros de 100 bytes, cada petición contestada tras sincronizar:

| clientes × registros por petición | producir | leer (un lector, 1 MiB por fetch) |
|---|---:|---:|
| 1 × 100 | 95 k registros/s | 164 k/s |
| 8 × 500 | 344 k/s | 166 k/s |
| 32 × 500 | 582 k/s | 164 k/s |
| 8 × 2000 | 697 k/s | 164 k/s |

107 MiB de RSS. La lectura va en JSON a un solo lector; con varios lectores (uno por partición, como un
grupo), cada uno va por su lado. La sincronización es `fs.sync_data`: protege de una caída del proceso
o del sistema (el `kill -9` de arriba), no de un corte de luz con la caché del disco sin vaciar.

## Hallazgos de dogfood

En `../findings/open/raybus-1.27.85.md`:

- **#296 [D/E]**: un submódulo puede redefinir `join` (el módulo raíz no), y su función tapa al builtin
  en todo el archivo. Una `get` propia tapa el `m.get(k)` de `Map` por UFCS. Los errores no dicen qué
  función ganó.

Lo que salió bien: los 6 tests pasaron en nativo a la primera. El CRC estaba en `std/inflate`
(`crc32`, `crc32_update`). `fs.try_lock`, `fs.seek` + `read_bytes`, `fs.rename` y el patrón actor dieron
un log que sobrevive al `kill -9` sin perder un registro confirmado.
