<!-- almeng-guide-source-sha256: fd70cb99938fe933ac8ea14cf562ba9a167f54665bc40b880b8578d25c2fd00d -->

<a name="top"></a>

# Guía de uso de 알맹Re

[한국어](ko.md) · [English](en.md) · [日本語](ja.md) · [简体中文](zh-Hans.md) · [Français](fr.md) · [Español](es.md) · [Tiếng Việt](vi.md)

[← 알맹Re](../../README.md) · [PDF](pdf/AlmaengRe-User-Guide-es.pdf)

**Abre, recorre, compara, etiqueta y edita tus imágenes en el Mac**

Una guía práctica de la versión de desarrollo 0.12 actual. Empieza por abrir una carpeta de imágenes y consulta después el capítulo correspondiente a lo que quieras hacer. Los nombres de los menús siguen la interfaz en español de la aplicación.

Versión 0.12.0 · A fecha de 2026-10-05

> Las capturas muestran la aplicación real con la interfaz en coreano e imágenes sintéticas de demostración. Las anotaciones numeradas y las explicaciones están traducidas al español; los píxeles de las capturas no se modifican. No se utiliza ninguna colección personal de fotos.

## Contenido

- [1. Abrir imágenes, carpetas y archivos ZIP](#open)
- [2. Recorrer las imágenes y concentrarse en una foto](#viewer)
- [3. Buscar y seleccionar en Todo a la vista](#overview)
- [4. Comparar dos colecciones de imágenes](#compare)
- [5. Etiquetar fotos con el teclado](#tags)
- [6. Configurar nombres, colores y seguimiento de etiquetas](#tag-editor)
- [7. Buscar fotos por ubicación](#map)
- [8. Consultar información y metadatos de la imagen](#information)
- [9. Editar una imagen y exportar una copia](#editing)
- [10. Renombrar, redimensionar, convertir y compartir por lotes](#batch)
- [11. Entender la ampliación con IA, el HDR y la carga](#quality)
- [12. Reproducir un álbum o establecer el fondo de pantalla](#slideshow)
- [13. Adaptar la aplicación a tu forma de trabajar](#settings)
- [14. Atajos y solución rápida de problemas](#shortcuts)
- [Atajos de un vistazo](#shortcut-reference)

---

<a name="open"></a>

## 1. Abrir imágenes, carpetas y archivos ZIP

Usa Abrir… para cualquier tipo de entrada. Una foto, una carpeta o un archivo ZIP se recorren después de la misma manera.

### Cómo hacerlo

1. Inicia 알맹Re en macOS 14 o posterior. Elige Abrir… en la pantalla de inicio, la barra de herramientas o el menú Archivo, o pulsa ⌘O.
2. Elige una carpeta para recorrer sus imágenes. Elige una sola imagen para empezar por ella y continuar con las demás de la misma carpeta. Si seleccionas varias imágenes, solo se abrirán las seleccionadas.
3. Elige un archivo ZIP para ver las imágenes compatibles que contiene, incluidas las de sus subcarpetas. También puedes abrir archivos desde Finder o arrastrar imágenes y carpetas a la aplicación.

### Carpetas y favoritas

El Árbol de carpetas se despliega según sea necesario. Haz clic en el nombre de una carpeta para abrirla, usa la flecha hacia arriba para subir y actualiza después de hacer cambios en Finder. Fija una carpeta encima del árbol para acceder rápidamente. Abrir una carpeta normal no incluye automáticamente todas sus subcarpetas.

### Los ZIP son de solo lectura

Las imágenes se extraen en una carpeta temporal mientras el archivo está abierto. Exporta una copia antes de renombrarlas o editar sus metadatos de origen. La aplicación no reescribe el ZIP. Admite archivos sin compresión o con Deflate; rechaza los cifrados y otros métodos de compresión. Los límites son 2 GiB por archivo ZIP, 10 000 entradas, 256 MiB por entrada extraída y 1 GiB de datos extraídos en total.

### Retomar donde lo dejaste

La aplicación restaura la última colección, la imagen seleccionada, el modo de vista y la búsqueda cuando es posible. Si se desconecta una unidad o cambian los permisos, usa Abrir… de nuevo. Los ajustes de edición y los resultados de IA sin guardar no se restauran.

### Conviene saber

- Seleccionar carpetas e imágenes individuales a la vez las reúne sin duplicados. En Comparación de imágenes, Abrir… cambia el contenido del panel A o B activo y desbloqueado. Ayuda → Uso básico abre una guía breve dentro de la aplicación. Ayuda → Guía detallada (GitHub) abre la guía completa en tu idioma en GitHub, en el navegador predeterminado.

[Volver arriba](#top)

---

<a name="viewer"></a>

## 2. Recorrer las imágenes y concentrarse en una foto

El Visor muestra entre una y diez imágenes a la vez. Amplía para examinar detalles u oculta los controles de alrededor para concentrarte en la foto.

![El Visor principal, con los controles de visualización alrededor de la imagen.](figures/viewer.png)

**Pantalla 01.** El Visor principal, con los controles de visualización alrededor de la imagen.

1. **Modos de vista** — Cambia entre Visor, Todo a la vista, Vista de mapa y Comparación de imágenes.
2. **Buscar y organizar** — Busca nombres de archivo y usa los controles de formato, etiquetas y orden de la colección abierta.
3. **Controles de visualización** — Recorre las imágenes, ajusta el zoom, cambia cuántas se muestran y elige el método de desplazamiento.

### Cómo hacerlo

1. Elige Visor en la parte superior. Usa ← y → para avanzar. Ajusta el número de imágenes por vista con su control o con \[ y \]; la cuadrícula se adapta a la forma de la ventana.
2. Pellizca el trackpad o usa = y − para cambiar el zoom. Pulsa 0 para Ajustar a la ventana y 1 para Tamaño real. Elige un método de desplazamiento en los controles inferiores o en Ajustes → General.
3. Pulsa F, haz doble clic en una foto o da un toque breve a Espacio para activar o salir del modo de concentración. Pulsa Esc para volver. Pantalla completa es una orden distinta: ⌃⌘F.

### Avanzar por varias imágenes

En el visor normal, ←/→ avanza el número de imágenes configurado por vista. ⌥←/⌥→ también mueve una vista completa cuando se muestran varias imágenes. En el modo de etiquetado, las flechas solas avanzan una foto cada vez y las flechas con Opción siguen avanzando una vista completa.

### Controles de desplazamiento

Elige arrastrar con el botón izquierdo, Espacio + botón izquierdo, botón derecho, botón central o dos dedos en el trackpad. Los atajos ⌃⌥1–5 seleccionan un método; no mueven la foto por sí mismos. Los gestos horizontales cambian de imagen cuando no se están usando para desplazar la foto ampliada.

### Controles del modo de concentración

La × inferior oculta solo la barra flotante de controles. Vuelve a abrirla con el botón junto al nombre del archivo. La × superior sale del modo de concentración. Los botones siguen disponibles aunque ocultes los nombres de archivo. Un toque breve a Espacio no cambia el modo mientras escribes o si esa tecla tiene un atajo personalizado.

### Conviene saber

- Las miniaturas pueden mostrarse a la izquierda, derecha, arriba o abajo, u ocultarse. Esc cierra primero el modo temporal activo y después permite volver del Visor a Todo a la vista.

[Volver arriba](#top)

---

<a name="overview"></a>

## 3. Buscar y seleccionar en Todo a la vista

Todo a la vista distribuye la colección actual en una cuadrícula de miniaturas. Úsala para examinar una carpeta, delimitar una selección y preparar una operación por lotes.

![Todo a la vista combina la cuadrícula con la búsqueda y los controles de selección y tamaño.](figures/overview.png)

**Pantalla 02.** Todo a la vista combina la cuadrícula con la búsqueda y los controles de selección y tamaño.

1. **Cuadrícula de miniaturas** — Haz clic, selecciona un intervalo o arrastra por las tarjetas; haz doble clic para abrir una foto.
2. **Búsqueda y filtros** — Reduce la colección abierta sin modificar los archivos.
3. **Tamaño y selección** — Ajusta el tamaño de las vistas previas y utiliza las acciones de las imágenes seleccionadas para trabajar por lotes.

### Cómo hacerlo

1. Elige Todo a la vista o pulsa G. Ajusta el tamaño de las miniaturas para ver más imágenes o vistas previas mayores. Haz doble clic en una miniatura para abrirla en el Visor.
2. Escribe en Buscar nombres de archivo. La búsqueda ignora mayúsculas y minúsculas; todos los términos separados por espacios deben aparecer en el nombre. Elige uno o varios formatos, o Todos los formatos para quitar ese filtro.
3. Haz clic para seleccionar, ⌘ + clic para añadir o quitar una imagen y ⇧ + clic para seleccionar un intervalo. Arrastra un rectángulo desde una imagen o un espacio vacío para seleccionar las tarjetas que toque.

### Atajos de selección

Mantén Mayús al empezar el rectángulo para añadir a la selección existente. Mantén ⌘ para alternar la selección de las imágenes del rectángulo. Esc restaura la selección anterior a ese arrastre. ⌘A selecciona todas las imágenes de la lista visible actual.

### Ordenar la lista actual

Ordena por nombre, fecha de modificación, fecha de creación, tamaño del archivo o dirección GPS. El orden por nombre coloca 2 antes que 10. El orden GPS lee los metadatos de ubicación y sitúa al final las imágenes sin GPS. La búsqueda y las restricciones de formato, etiquetas y mapa se combinan; ninguna modifica los originales.

### Números y tamaño de vista previa

El control # muestra u oculta los números de las miniaturas. Los números grandes se colocan fuera de las fotos pequeñas para no taparlas. El tamaño se recuerda; su intervalo es de 44,8 a 665,6 puntos, aunque cada tarjeta queda limitada por el ancho de la ventana.

### Conviene saber

- La búsqueda usa el nombre del archivo, no los objetos, el contenido visual ni el texto OCR. Si faltan imágenes esperadas, borra la búsqueda y los filtros activos antes de volver a abrir la carpeta.

[Volver arriba](#top)

---

<a name="compare"></a>

## 4. Comparar dos colecciones de imágenes

Comparación de imágenes conserva dos colecciones independientes, A y B, lado a lado o una encima de otra. Sirve para comparar versiones o revisar dos carpetas.

![Dos colecciones en Comparación de imágenes.](figures/compare.png)

**Pantalla 03.** Dos colecciones en Comparación de imágenes.

1. **Paneles A y B** — Cada panel tiene su propia colección y su control Abrir….
2. **Comportamiento de la comparación** — Elige el emparejamiento, el destino de navegación, la repetición del lado corto y el zoom vinculado.
3. **Bloqueos y miniaturas** — Fija un lado o elige otra imagen en la tira de miniaturas de ese panel.

### Cómo hacerlo

1. Elige Comparación de imágenes o pulsa ⌃⌥C. Usa Elegir carpetas para comparar… para seleccionar A y B en ese orden, o el botón Abrir… de cada panel.
2. Usa Orden de la lista para listas independientes. Elige Nombres coincidentes para emparejar nombres sin extensión: 001.jpg coincide con 001.png. Cuando falta una pareja, su lado se muestra vacío.
3. En Navegación de imágenes, elige Solo A, Ambos o Solo B. Usa las flechas comunes o las miniaturas del panel para avanzar. Activa Vincular zoom y desplazamiento para examinar posiciones relativas correspondientes.

### Navegación y repetición

Elegir Solo A o Solo B cambia a Orden de la lista. Nombres coincidentes restaura la navegación por parejas. Con Ambos, Repetir el lado más corto repite la lista corta mientras avanza la larga; si se desactiva, la corta permanece en su última imagen. La repetición funciona en Orden de la lista.

### Bloqueos

Bloquear fija la imagen, el zoom y la posición de un panel. Bloquea B para recorrer A y A para recorrer B. Desbloquear los dos devuelve la navegación a Ambos; bloquearlos detiene la navegación. Las miniaturas de un panel bloqueado se pueden seguir examinando y desplazando.

### Originales y estado guardado

La comparación muestra los originales sin los ajustes de edición del visor normal. Sal de ella para editar, trabajar por lotes o configurar el fondo de pantalla. Esc vuelve a la vista anterior. Se recuerdan la disposición, la vinculación, las preferencias de navegación y las últimas entradas y posiciones A/B.

### Conviene saber

- ⌥←/⌥→ recorre solo A; ⇧⌥←/⇧⌥→ recorre solo B. Nombres coincidentes ignora la extensión, las mayúsculas y las representaciones Unicode equivalentes.

[Volver arriba](#top)

---

<a name="tags"></a>

## 5. Etiquetar fotos con el teclado

El etiquetado permite asignar varias etiquetas personales a una foto mientras navegas. Son marcas de la aplicación, no acciones ejecutadas sobre el archivo original.

![El modo de etiquetado, las teclas asignadas y sus marcas de color.](figures/tags.png)

**Pantalla 04.** El modo de etiquetado, las teclas asignadas y sus marcas de color.

1. **Modo de etiquetado** — Activa o desactiva el modo; al desactivarlo vuelven las funciones habituales de las teclas.
2. **Teclas de etiquetas** — Usa 1–4, QWER y ASDF o haz clic en un botón de etiqueta. Una foto puede llevar varias marcas.
3. **Filtro Etiquetas** — Reúne las fotos coincidentes o sin etiquetar de la colección abierta.

### Cómo hacerlo

1. Abre fotos y haz clic en Etiquetado, usa el menú Etiquetas de fotos o pulsa ⌘⇧M. En Comparación de imágenes, las etiquetas se aplican a la foto del panel activo.
2. Recorre las fotos con ← y →. Pulsa las teclas físicas 1–4, QWER o ASDF para añadir o quitar sus etiquetas. Una segunda pulsación retira la etiqueta; varias pueden coexistir.
3. Sal del etiquetado con ⌘⇧M, Esc o el botón de cierre del panel. Usa el filtro Etiquetas para mostrar Cualquiera de las etiquetas elegidas, Todas las etiquetas elegidas o Fotos sin etiquetar.

### Mantener un ritmo constante

Añadir una etiqueta no avanza automáticamente. Mientras el etiquetado está activo, la lista filtrada permanece fija para que varias pulsaciones afecten a la misma foto. Los resultados se actualizan al salir del modo. Las flechas solas avanzan una foto cada vez.

### Qué significan las teclas

Los nombres iniciales, incluidos Eliminar y Subir, son solo ejemplos. Las teclas nunca eliminan, suben, mueven ni editan una foto. Cámbialos según tu trabajo, por ejemplo Candidata para imprimir o Edición terminada.

### Guardado local

Las etiquetas asignadas, sus nombres y colores y los informes se guardan en la base SQLite local ~/Library/Application Support/org.openimageviewer.ImageViewer/PhotoMarks.sqlite. Se conservan al reiniciar, son independientes de EXIF y no se sincronizan mediante XMP ni una fototeca en la nube.

### Conviene saber

- Las teclas de etiquetas tienen prioridad sobre las acciones normales durante el etiquetado. Por ejemplo, 1 y F aplican etiquetas en vez de Tamaño real o modo de concentración. Sal del etiquetado para recuperar esos atajos normales.

[Volver arriba](#top)

---

<a name="tag-editor"></a>

## 6. Configurar nombres, colores y seguimiento de etiquetas

Da a las doce teclas nombres adecuados para tu trabajo. Las asignaciones se comparten entre carpetas; el seguimiento y sus informes conservan las etiquetas cuando reconocen cambios en los archivos.

![El editor compartido de nombres y colores de etiquetas.](figures/tag-editor.png)

**Pantalla 05.** El editor compartido de nombres y colores de etiquetas.

1. **Nombres por tecla** — Cada tecla fija tiene un nombre editable, compartido en todas las carpetas.
2. **Colores** — Elige una señal visual coherente entre los diez colores de la paleta.
3. **Vista previa y guardado** — Comprueba las asignaciones y guarda los cambios para conservarlos en la próxima sesión.

### Cómo hacerlo

1. Abre Ajustes → Etiquetas de fotos, o elige Etiquetas de fotos → Editar nombres y colores…. Puedes configurar las asignaciones antes de abrir fotos.
2. Escribe un nombre para cada tecla y elige uno de los diez colores. La vista previa Etiquetas de las teclas muestra el resultado mientras escribes.
3. Haz clic en Guardar para aplicar los nombres y colores en todas partes. Revertir cambios en Ajustes restaura las últimas asignaciones guardadas; Cancelar cierra el editor independiente sin guardar.

### Marcas visuales coherentes

Los colores aparecen en el panel de etiquetas, los menús, los filtros y las insignias de las miniaturas. Una marca de verificación y un fondo seleccionado también indican la asignación; el color no es la única señal. Cambiar un nombre o color no elimina las etiquetas ya aplicadas.

### Cambios de nombre y ubicación

La aplicación registra marcadores de macOS y la identidad de los archivos etiquetados. Renombrar desde la aplicación conserva las etiquetas. Los cambios de Finder dentro del mismo volumen pueden reconocerse al arrancar, abrir la carpeta o comprobar el informe. Esa comprobación no recarga la lista de fotos: vuelve a abrir o actualiza la carpeta afectada. Las imágenes ZIP se identifican por el archivo comprimido y su ruta interna.

### Límites del seguimiento

Las copias son fotos independientes; un archivo nuevo en una ruta antigua no hereda las etiquetas. Otro volumen, un reemplazo, marcadores no disponibles o cambios de permisos pueden impedir la reconexión. No disponible no significa eliminado: el disco puede estar desconectado. Las etiquetas antiguas basadas en rutas requieren abrir la foto en su ubicación original antes de moverla.

### Conviene saber

- Abre Etiquetas de fotos → Informe de archivos clasificados…: los eventos No disponible, Nombre o ubicación cambiados y Encontrado de nuevo conservan fecha, etiquetas y rutas al reiniciar. Se comprueba al arrancar, abrir el informe y con Volver a comprobar. La aplicación no busca por todo el disco ni analiza el contenido. Incluye originales y datos locales en tus copias de seguridad habituales del Mac.

[Volver arriba](#top)

---

<a name="map"></a>

## 7. Buscar fotos por ubicación

Vista de mapa sitúa en un mapa las fotos con metadatos GPS. Combina hasta tres áreas para recorrer juntas las imágenes de varios lugares.

![Vista de mapa con áreas seleccionables y un resumen de las fotos coincidentes.](figures/map.png)

**Pantalla 06.** Vista de mapa con áreas seleccionables y un resumen de las fotos coincidentes.

1. **Herramientas de área** — Añade un radio, un rectángulo, un contorno a mano alzada o la extensión visible del mapa.
2. **Controles de las áreas** — Mueve y redimensiona el área activa; combina un máximo de tres áreas.
3. **Recorrer los resultados** — Abre las fotos coincidentes en el Visor o Todo a la vista manteniendo el filtro geográfico.

### Cómo hacerlo

1. Abre una colección y elige Vista de mapa. Las fotos cercanas se agrupan en miniaturas apiladas con un contador. Haz clic en una ubicación para previsualizar sus imágenes y usa Ver foto para abrir una.
2. Elige Radio o Rectángulo para añadir un área en el centro actual del mapa. Arrastra el control numerado para moverla y el pequeño control de tamaño para redimensionarla. También puedes introducir el radio en kilómetros.
3. Elige Área a mano alzada y dibuja un contorno, o añade Área actual del mapa. Combina hasta tres áreas y abre el Visor o Todo a la vista. Fotos del área permite renombrar, convertir, cambiar el tamaño o compartir directamente los archivos coincidentes.

### Combinar y editar áreas

Una foto dentro de cualquiera de las áreas seleccionadas se incluye una sola vez, aunque se solapen. Selecciona Área 1, 2 o 3 para editarla, usa su × para eliminarla o borra todas. Esc cancela el dibujo a mano alzada o revierte el movimiento o cambio de tamaño en curso.

### Conservar la colección seleccionada

Abrir la selección en el Visor o Todo a la vista mantiene la restricción geográfica y los filtros de nombre, formato y etiquetas. En la vista previa de un lugar, Esta foto actúa sobre la imagen actual y Todas las fotos de este lugar sobre el grupo. Quitar área del mapa vuelve a la lista sin restricción geográfica, incluidas las fotos sin GPS; abrir una foto fuera del área elimina esa restricción.

### Carga y estado guardado

Los fondos del mapa necesitan conexión a Internet. Las fotos sin GPS no aparecen como miniaturas del mapa. Leer las ubicaciones de una colección grande puede tardar. Las áreas se restauran con la última sesión; abrir una carpeta nueva borra la selección anterior.

### Conviene saber

- Si no coincide ninguna foto, amplía o mueve el área y revisa los demás filtros. Los botones para abrir la selección no están disponibles mientras se calculan los resultados o si están vacíos.

[Volver arriba](#top)

---

<a name="information"></a>

## 8. Consultar información y metadatos de la imagen

El botón circular i sigue siendo Información de la imagen. Describe la foto actual; la historia de la aplicación está en Ayuda → Acerca de la app.

### Cómo hacerlo

1. Selecciona una foto y haz clic en el botón circular i, o usa Navegación → Panel de información.
2. Consulta el tamaño del archivo, las dimensiones, los datos de color y la información de cámara/EXIF disponible. Si hay GPS, el panel muestra un mapa de Apple; Google Maps abre las mismas coordenadas fuera de la aplicación.
3. Para cambiar campos compatibles del archivo o sus metadatos integrados, abre Editar información de la imagen, modifica los valores y revísalos antes de Guardar.

### Guardar metadatos modifica el archivo

A diferencia de los ajustes visuales, los cambios de metadatos se escriben en el archivo de origen. Los campos incluyen nombre, fecha de modificación, descripción, derechos, DPI, datos de cámara y GPS, cuando el formato lo admite. El editor prepara un archivo temporal antes de sustituir el de origen. Los campos integrados no compatibles se desactivan; las imágenes ZIP son de solo lectura.

### Quitar o corregir valores

Vaciar un campo de texto editable elimina esa etiqueta de metadatos al guardar. Desactivar GPS quita las etiquetas estándar de ubicación EXIF/XMP. Las coordenadas requieren latitud y longitud. Cambiar la extensión no convierte la imagen; usa Exportar o Convertir, redimensionar y comprimir.

### Interpretar el histograma

Los histogramas RGB y de luminancia describen una vista previa SDR ponderada por transparencia y siguen los ajustes de edición. Los porcentajes de negro y blanco cuentan píxeles de la vista previa cuyos canales RGB valen todos 0 o 255. No es un histograma del sensor RAW ni una medida del rango de brillo HDR original.

### Conviene saber

- Conserva una copia antes de hacer cambios de metadatos que puedas querer deshacer. El icono i corresponde a la foto; Ayuda → Acerca de la app abre la presentación de la aplicación y sus licencias.

[Volver arriba](#top)

---

<a name="editing"></a>

## 9. Editar una imagen y exportar una copia

Edición de imagen permite previsualizar cambios sin sobrescribir el original. Exporta el resultado antes de salir: los ajustes visuales solo se conservan durante la sesión actual.

![El panel de edición junto a la vista previa de la imagen actual.](figures/editing.png)

**Pantalla 07.** El panel de edición junto a la vista previa de la imagen actual.

1. **Controles de edición** — Recorta, gira, voltea y ajusta el tono, el color y el detalle.
2. **Vista previa de la imagen** — Examina el resultado actual; usa Tamaño real para ajustar detalles.
3. **Exportar — debajo del panel** — Desplázate hacia abajo en el panel de edición o pulsa ⌘E para guardar una copia antes de cerrar la aplicación.

### Cómo hacerlo

1. Selecciona una foto y haz clic en el botón Edición de imagen con forma de deslizadores. Si lo abres desde Todo a la vista, se abre esa foto en el Visor.
2. Recorta arrastrando un rectángulo sobre la imagen. Muévelo desde dentro, ajusta sus esquinas o introduce una proporción y dimensiones. Aplica el recorte; cancelar su ventana conserva las ediciones anteriores. Gira en pasos de 90° o usa Reflejo horizontal / Reflejo vertical.
3. Ajusta los controles de luz, color y detalle. Elige un formato de salida disponible y la calidad en el panel de edición; haz clic en Exportar… o pulsa ⌘E para guardar un archivo nuevo.

### Ajustes

Usa exposición, brillo, contraste, altas luces, sombras, punto negro y blancos para el tono; tono, temperatura, intensidad de color y saturación para el color. Las curvas ofrecen cinco puntos para RGB o cada canal. El mezclador de ocho colores ajusta tono, saturación y luminosidad por color. Textura, Claridad, Borrar neblina y Estilos de película añaden otros controles.

### Restablecer y comprobar

Restablecer elimina todos los ajustes visuales de la foto actual. Quitar recorte conserva los demás. Pulsar otra vez el mismo botón de reflejo deshace ese volteo. Comprueba la nitidez y la reducción de ruido en Tamaño real y en el resultado exportado.

### Guardar antes de salir

Cada foto conserva sus ajustes mientras la aplicación sigue abierta. El siguiente inicio no los restaura. La exportación propone un nombre terminado en -edited y bloquea el guardado sobre el original. Los formatos disponibles dependen de los codificadores de macOS.

### Conviene saber

- Comparación de imágenes muestra los originales sin estos ajustes. Ampliación con IA también usa la imagen de origen sin las ediciones del visor; exporta primero una copia editada si quieres ampliar ese resultado.

[Volver arriba](#top)

---

<a name="batch"></a>

## 10. Renombrar, redimensionar, convertir y compartir por lotes

Usa los archivos seleccionados en el Visor, Todo a la vista, los resultados filtrados por etiquetas o el mapa. Renombrar cambia los nombres originales; convertir crea copias y Compartir archivos… abre las opciones de macOS.

![La ventana de conversión por lotes, los ajustes de tamaño y la vista previa de los archivos.](figures/batch.png)

**Pantalla 08.** La ventana de conversión por lotes, los ajustes de tamaño y la vista previa de los archivos.

1. **Formato y calidad** — Elige la codificación de salida y su calidad cuando el formato lo permita.
2. **Reducción proporcional** — Conserva el tamaño o fija el lado más largo o un porcentaje; Reducir peso propone JPEG, 1920 píxeles y calidad del 75 %.
3. **Destino y vista previa** — Elige la carpeta, revisa los nombres y convierte. Se conservan los originales.

### Cómo hacerlo

1. Selecciona imágenes con ⌘ + clic, ⇧ + clic o ⌘A. En Todo a la vista también puedes arrastrar un rectángulo de selección. Usa el menú de selección, el menú contextual o Imagen; en el mapa, usa Fotos del área, Esta foto o Todas las fotos de este lugar.
2. En Renombrar por lotes…, conserva o sustituye el nombre, o busca y reemplaza texto. Con Usar un nombre de clasificación, elige explícitamente una etiqueta: solo se renombran los archivos seleccionados que la tienen. Revisa la lista de antes y después.
3. Abre Convertir, redimensionar y comprimir…, elige el formato, la calidad y Tamaño de imagen y luego la carpeta. Lado más largo o Porcentaje reduce proporcionalmente tras los ajustes y el recorte, sin ampliar imágenes pequeñas. Reducir peso establece JPEG, 1920 píxeles y calidad del 75 %.

### Numeración y validación de nombres

El modo de clasificación crea Subida01, Subida02… sin separador. Para 1–99 archivos coincidentes usa dos dígitos; a partir de 100 usa tres, comenzando en 001, y aumenta los dígitos según sea necesario. Sigue el orden de la lista y conserva la extensión. Los otros modos permiten elegir inicio, incremento, dígitos y separador. Los nombres inválidos o repetidos impiden el cambio. No se renombran imágenes dentro de ZIP.

### Extensión, formato y peso

Renombrar una extensión normaliza mayúsculas y variantes del mismo formato, como .jpg/.jpeg o .tif/.tiff. Pasar de HEIC a JPEG exige convertir para cambiar la codificación. Reducir el peso depende del contenido, formato, calidad y dimensiones; no garantiza un número exacto de bytes y puede producir un archivo más grande.

### Copias convertidas y compartir con macOS

La conversión aplica los ajustes y preserva los originales y sus etiquetas; las copias son independientes. Si un nombre ya existe, se añade un número. Las animaciones y las imágenes de varias páginas guardan solo su primer fotograma. Detenerla conserva los archivos terminados y muestra los guardados, fallidos y no procesados. Compartir archivos… envía los archivos originales, sin aplicar los ajustes de vista previa. Para enviar copias editadas o reducidas, usa Compartir archivos terminados… tras convertir, incluso si solo se completó parte del lote.

### Conviene saber

- Filtra por búsqueda, formato, etiquetas o mapa antes de seleccionar todo. Revisa el número y la lista antes de renombrar originales. Los servicios disponibles para compartir, como AirDrop, dependen de macOS y de su configuración.

[Volver arriba](#top)

---

<a name="quality"></a>

## 11. Entender la ampliación con IA, el HDR y la carga

Ampliación de alta calidad cambia la interpolación de pantalla. Ampliación con IA crea una imagen mayor que puedes guardar. La salida HDR es una preferencia de visualización, no una prueba de que la foto sea HDR.

### Cómo hacerlo

1. Para suavizar la visualización, activa Ampliación de alta calidad. Su comparación lado a lado o arriba y abajo muestra la misma foto con zoom y desplazamiento vinculados; Esc cierra esa comparación.
2. Para crear una imagen 2×, selecciona una foto, abre Ampliación con IA… y haz clic en Iniciar ampliación con IA. Examina Comparar con el original y Píxeles reales; después usa Guardar copia PNG….
3. Usa Salida HDR activada / Salida HDR desactivada para permitir o impedir la visualización de rango ampliado. En Ajustes → General → Carga de imágenes, elige Prioridad, Cómodo, Normal o Lento según tu trabajo.

### Salida y límites de la IA

El modelo incluido funciona localmente con Core ML: las fotos no se suben y no hay que descargar un modelo durante el uso. Se duplican el ancho y el alto. El resultado es PNG sRGB SDR de 8 bits, con la transparencia interpolada aparte. Las animaciones usan el primer fotograma y no se incluyen los ajustes del visor. La salida se limita a un máximo de 64 millones de píxeles y puede ser menor en Mac con poca memoria. Guarda antes de cerrar; los detalles de IA son una estimación.

### Formatos y rendimiento

Los formatos que se pueden leer y escribir dependen del macOS en uso. La aplicación añade decodificación de QOI y variantes comunes de PCX, además de una alternativa para SVG/SVGZ. BPG y .clip no están incluidos. Cómodo es el modo de carga predeterminado. Todos los modos reducen el ritmo ante presión de memoria, calor, bajo consumo, otras aplicaciones o un almacenamiento más lento.

### Conviene saber

- Durante la navegación rápida puede seguir visible una vista previa pequeña o la foto anterior hasta que esté lista la imagen final. No se ofrece IA 4×, salida HDR de IA ni ampliación con IA por lotes.

[Volver arriba](#top)

---

<a name="slideshow"></a>

## 12. Reproducir un álbum o establecer el fondo de pantalla

Álbum de fotos avanza automáticamente por la lista actual, una imagen cada vez en modo de concentración. El fondo de pantalla usa una copia aparte preparada para las pantallas elegidas.

### Cómo hacerlo

1. Abre una lista con al menos dos fotos. Elige Navegación → Álbum de fotos → Reproducir álbum o pulsa ⌃⌥P.
2. Usa los controles de reproducción para pausar. Elige un intervalo de 1 a 300 segundos y si se repetirá, desde el control de tiempo o Ajustes → General → Álbum de fotos.
3. Para establecer el fondo, vuelve al visor normal y elige Imagen → Usar la imagen actual como fondo de pantalla… o pulsa ⌃⌥W. Selecciona la pantalla actual o todas las conectadas, Llenar la pantalla o Mostrar la foto completa, y si se aplicarán los ajustes actuales; después aplica.

### Comportamiento de la reproducción

El intervalo predeterminado es de cinco segundos con repetición activada. El tiempo empieza a contar cuando aparece una vista previa o la imagen, de modo que la carga no consume el intervalo de visualización. Navegar manualmente o cambiar el intervalo reinicia el contador. Sin repetición, se detiene en la última imagen.

### Pausas automáticas

La reproducción se pausa al salir del modo de concentración, cambiar de aplicación, entrar en reposo o iniciar una operación de archivos. La pantalla permanece activa solo durante la reproducción. Al reiniciar se restauran los ajustes, pero el álbum nunca empieza automáticamente.

### Copias para el fondo

La aplicación crea un PNG sin alterar el original. Usa el primer fotograma de las animaciones y prepara el HDR como SDR. Las copias excluyen EXIF/GPS, se adaptan a la pantalla hasta 8192 píxeles y permanecen en la carpeta Application Support/Wallpapers de la aplicación. Los otros espacios de escritorio siguen el comportamiento de macOS. Las copias antiguas no se eliminan automáticamente porque otro espacio puede seguir usándolas.

### Conviene saber

- Si la reproducción no está disponible, comprueba que la lista filtrada tenga al menos dos fotos y que no estén activos el etiquetado, la Comparación de imágenes u otra operación.

[Volver arriba](#top)

---

<a name="settings"></a>

## 13. Adaptar la aplicación a tu forma de trabajar

Ajustes reúne las opciones de visualización, los atajos personalizados, las etiquetas y las asociaciones de archivos. Muchas preferencias se recuperan automáticamente al volver a iniciar.

![Ajustes agrupa las preferencias principales en cuatro pestañas.](figures/settings.png)

**Pantalla 09.** Ajustes agrupa las preferencias principales en cuatro pestañas.

1. **Pestañas de Ajustes** — General, Atajos, Etiquetas de fotos y Asociaciones de archivos cubren tareas distintas.
2. **Preferencias de visualización** — Configura pantalla, miniaturas, nombres de archivo, navegación y carga.
3. **Explicaciones junto a los controles** — Lee el texto bajo un control o sitúa el puntero encima para conocer su comportamiento.

### Cómo hacerlo

1. Abre 알맹Re → Ajustes…. En General, elige la salida HDR/EDR, la posición de las miniaturas, el tamaño de los nombres, la ampliación de alta calidad, la visibilidad del árbol y si la navegación vuelve al principio.
2. Usa Etiquetas de fotos para guardar nombres y colores compartidos, y Atajos para elegir teclas y modificadores. Sitúa el puntero sobre los controles para ver sus explicaciones.
3. Para que Finder abra ciertos formatos con esta aplicación, coloca 알맹Re.app en un lugar estable, como Aplicaciones, abre Asociaciones de archivos, selecciona solo los grupos de formatos deseados y aplica.

### Idioma

La interfaz sigue el idioma que macOS asigna a la aplicación. Cámbialo en Ajustes del Sistema → General → Idioma y región → Aplicaciones. La aplicación admite coreano, inglés, chino simplificado, japonés, francés, español, árabe y vietnamita; esta colección de guías cubre siete idiomas.

### Preferencias recordadas

Se conservan el tamaño de las miniaturas, la ampliación de alta calidad, los nombres de archivo, las preferencias de carga, los favoritos, las etiquetas y los atajos. La última colección y posición pueden restaurarse si los archivos siguen accesibles. La comparación de calidad de ampliación empieza desactivada tras reiniciar. Los ajustes visuales y resultados de IA deben exportarse aparte.

### Asociaciones de archivos

Solo se modifican los grupos de formatos marcados. macOS puede pedir confirmación. Mover la aplicación o conservar copias antiguas puede hacer que Finder abra otra versión; vuelve a aplicar las asociaciones desde la versión que quieras usar.

### Conviene saber

- General también enumera los formatos nativos disponibles en tu Mac y ofrece Vaciar caché de imágenes. Elige un modo de carga más lento para reducir el trabajo en segundo plano mientras usas otras aplicaciones.

[Volver arriba](#top)

---

<a name="shortcuts"></a>

## 14. Atajos y solución rápida de problemas

La referencia siguiente enumera las teclas de acción predeterminadas y las contextuales fijas. ⌘ significa Comando, ⌥ Opción, ⌃ Control y ⇧ Mayús.

![La pestaña Atajos muestra las acciones configurables y los conflictos.](figures/shortcuts.png)

**Pantalla 10.** La pestaña Atajos muestra las acciones configurables y los conflictos.

1. **Acciones** — Sitúa el puntero sobre el nombre de una acción para saber dónde y cómo funciona.
2. **Teclas y modificadores** — Elige la tecla y activa Control, Opción, Mayús o Comando.
3. **Conflictos y valores predeterminados** — Resuelve las combinaciones duplicadas o usa Restaurar valores predeterminados para empezar de nuevo.

### Cómo hacerlo

1. Abre Ajustes → Atajos para cambiar la tecla y los modificadores de una acción. Los cambios se guardan y las asignaciones actuales aparecen en los menús.
2. Revisa los indicadores de conflicto cuando uses la misma combinación para varias acciones. Sitúa el puntero sobre la acción, el selector de tecla, un modificador o el icono de conflicto para obtener ayuda. Restaurar valores predeterminados restablece las teclas configurables.
3. Si una tecla actúa de forma inesperada, sal del campo de texto y comprueba el modo actual. El etiquetado reserva sus doce teclas para etiquetas; la Comparación de imágenes da a las flechas con Opción su función de navegación A/B.

### No hay imágenes o coincidencias

Quita la búsqueda y los filtros de formato, etiquetas y mapa. Comprueba que este macOS pueda leer el formato. Puedes abrir una carpeta vacía para recorrer sus subcarpetas. Usa Abrir… para volver a abrir una unidad desconectada o una colección movida.

### Una orden está desactivada

Termina o cancela primero la operación de archivos actual. Sal de Comparación de imágenes para editar, convertir por lotes o configurar el fondo. Las imágenes ZIP no se pueden renombrar ni permiten reescribir metadatos de origen. Los botones de resultados del mapa esperan una selección no vacía y totalmente calculada.

### Espacio, Esc y flechas con Opción

Espacio activa el modo de concentración solo cuando ninguna acción personalizada usa Espacio solo y no estás escribiendo. Esc sale del modo activo o cancela un gesto de selección. La navegación por páginas con Opción en el Visor es fija, pero cede prioridad a una acción personalizada del visor normal asignada a esa combinación.

### Conviene saber

- Los botones i circular y de deslizadores abren la información de la foto y la edición. Usa los botones o el menú Navegación; I y E no son atajos predeterminados para esos paneles en esta versión.

[Volver arriba](#top)

---

<a name="shortcut-reference"></a>

## Atajos de un vistazo

| Teclas | Acción | Cuándo se aplica |
| --- | --- | --- |
| ← / → | Imagen o página anterior / siguiente | Configurable. El Visor avanza por el número de imágenes por pantalla; la comparación sigue Solo A / Ambos / Solo B. |
| ⌥← / ⌥→ | Página anterior / siguiente del visor | Teclas contextuales fijas cuando el Visor muestra varias imágenes, también durante el etiquetado; los atajos personalizados del visor tienen prioridad. |
| = / − | Ampliar / reducir | Configurable; se aplica al visor normal o a la vista comparativa activa. |
| 0 / 1 | Ajustar a la ventana / Tamaño real | Configurable. La tecla 1 sola aplica una etiqueta durante el etiquetado. |
| G | Alternar Todo a la vista | Acción de visualización configurable. |
| F | Alternar modo de concentración | Configurable. La tecla F sola aplica una etiqueta durante el etiquetado. |
| Space (tap) | Alternar modo de concentración | Gesto del Visor; inactivo al escribir o cuando una acción personalizada usa Espacio. Mantener Espacio para desplazar la imagen no cambia el modo de concentración. |
| ⌃⌘F | Alternar Pantalla completa | Atajo fijo del menú de la aplicación; independiente del modo de concentración. |
| \[ / \] | Mostrar menos / más imágenes por pantalla | Configurable; de 1 a 10 en el Visor. |
| ⌘O | Abrir imágenes, carpetas o archivos ZIP | Configurable; en comparación, abre en el panel activo desbloqueado. |
| ⌘E | Exportar imagen actual | Configurable; para el visor normal, no disponible en Comparación de imágenes. |
| ⌃⌥1 | Seleccionar desplazamiento con arrastre izquierdo | Configurable; selecciona un método en vez de mover la imagen. |
| ⌃⌥2 | Seleccionar Espacio + arrastre izquierdo | Selección configurable del método de desplazamiento. |
| ⌃⌥3 | Seleccionar desplazamiento con botón derecho | Selección configurable del método de desplazamiento. |
| ⌃⌥4 | Seleccionar desplazamiento con botón central | Selección configurable del método de desplazamiento. |
| ⌃⌥5 | Seleccionar desplazamiento con dos dedos en el trackpad | Selección configurable del método de desplazamiento. |
| ⌃⌥A | Alternar Ampliación de alta calidad | Ajuste de visualización configurable; no modifica los archivos exportados. |
| ⌃⌥6 / ⌃⌥7 | Comparar calidad de ampliación lado a lado / arriba y abajo | Configurable; dos representaciones de la misma imagen en el Visor. |
| ⌃⌥0 | Finalizar la comparación de calidad de ampliación | Configurable; Esc también cierra esta comparación. |
| ⌃⌥P | Reproducir / pausar Álbum de fotos | Configurable; necesita al menos dos fotos y disponibilidad del visor normal. |
| ⌃⌥W | Usar la imagen actual como fondo de pantalla | Configurable; abre las opciones del fondo fuera de Comparación de imágenes. |
| ⌃⌥C | Entrar / salir de Comparación de imágenes | Configurable; conserva la colección anterior del visor normal. |
| ⌥← / ⌥→ | Imagen anterior / siguiente solo en A | Acción de comparación configurable; A está a la izquierda o arriba. Un panel bloqueado permanece fijo. |
| ⇧⌥← / ⇧⌥→ | Imagen anterior / siguiente solo en B | Acción de comparación configurable; B está a la derecha o abajo. Un panel bloqueado permanece fijo. |
| ⌘⇧M | Alternar el modo de etiquetado | Atajo fijo del menú de la aplicación. |
| 1 2 3 4 · Q W E R · A S D F | Añadir/quitar las doce etiquetas de fotos | Posiciones físicas fijas; solo en etiquetado. Nombres y colores editables; las teclas no eliminan ni suben archivos. |
| ← / ↑ · → / ↓ | Foto anterior / siguiente durante el etiquetado | Navegación fija del etiquetado; una foto cada vez. |
| ⌘A | Seleccionar todas las imágenes de la lista actual | Atajo fijo de selección fuera de Comparación de imágenes; los campos de texto mantienen la selección de texto habitual. |
| Esc | Cancelar el gesto actual o salir del modo activo | Fijo. Sale del etiquetado, la comparación, la comparación de calidad de ampliación o la concentración; el Visor normal vuelve a Todo a la vista. También cancela gestos de selección de áreas. |

[Volver arriba](#top)
