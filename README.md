# TOPO_ROAD para SketchUp

## Fases 1–4: entrada, geometría vial y adaptación del terreno

La extensión añade **Extensiones → TOPO_ROAD → Configurar vía…** y un botón en la barra de herramientas. El formulario captura ancho total de calle, opción y ancho de bordillo, ancho y altura de acera, ancho de talud y pendiente máxima.

### Selección requerida

Selecciona exactamente dos grupos antes de validar:

- El terreno debe contener caras.
- El eje debe contener aristas y no contener caras.

La selección puede validarse desde el formulario. Los parámetros se aceptan solo cuando la selección es válida y los valores numéricos están dentro de rango. Al pulsar **Generar vía**, el motor ordena el eje, rechaza desconexiones y ramificaciones, genera estaciones Catmull–Rom con muestreo adaptativo (separación máxima de 5 m y desviación objetivo de 5 cm), interpola cotas directamente desde las caras trianguladas del grupo de terreno (incluyendo grupos/componentes anidados) y ajusta el perfil longitudinal. Esta lectura evita depender del orden de `raytest`; admite una tolerancia de ajuste de 0.25 m al borde de la malla por discrepancias pequeñas en planta. Después extruye la sección y crea cuatro grupos independientes: `Grupo de Vía`, `Grupo de Acera`, `Grupo de Bordillo` y `Grupo de Talud`. El ancho de bordillo está incluido dentro del ancho de acera. Los taludes enlazan el borde exterior de acera con cotas del terreno muestreadas en el ancho de proyección indicado.

Ante un error al generar, el plugin agrega el detalle Ruby, la traza y metadatos de transformación/extensión de los grupos a `%TEMP%\TOPO_ROAD_diagnostics.log`. El formulario muestra un identificador `TR-...` para encontrar el registro de ese intento. En ejes abiertos, la versión 0.4.6 limita los extremos al tramo donde la sección vial completa (calzada, acera y talud) queda dentro del área triangulada del terreno. La altura Z del grupo del eje no interviene en esta comprobación. Circuitos cerrados deben quedar cubiertos por el terreno en todo su recorrido.

Las coordenadas de los mensajes y el diagnóstico se presentan en metros aunque SketchUp almacene coordenadas internas en pulgadas. La versión 0.4.7 también corrige el modo de consulta de cobertura usado al recortar el eje: los puntos fuera del terreno se reportan como no cubiertos para que se pueda recortar el tramo abierto, en vez de interrumpir el análisis.

La Fase 4 corta la malla del terreno por la huella exterior de la vía, conserva la superficie fuera de ella y conserva la isla interior de circuitos cerrados. El borde de corte se cose al talud con triángulos. El generador bloquea trazados donde dos tramos no adyacentes se acercan hasta el ancho de la calzada. La fusión booleana de taludes que se solapan sin comprometer la calzada aún requiere validación geométrica adicional.

La excepción de pendiente máxima se aplica al tramo abierto que desciende monotónicamente desde una cota alta hasta una cota baja. Las Fases 1–4 están conectadas al botón de generación; valida la malla cortada y la costura en modelos representativos antes de usarla en producción.

### Instalación para desarrollo

Ejecuta `Instalar_o_actualizar_Vias_Topograficas.bat` para instalar o actualizar en SketchUp 2026. El script guarda una copia de seguridad de los archivos anteriores. Reinicia SketchUp después de instalar.
