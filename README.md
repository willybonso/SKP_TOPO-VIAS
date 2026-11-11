# TOPO_ROAD para SketchUp

## Fases 1–3: interfaz, motor del eje y extrusión

La extensión añade **Extensiones → TOPO_ROAD → Configurar vía…** y un botón en la barra de herramientas. El formulario captura ancho total de calle, opción y ancho de bordillo, ancho y altura de acera, ancho de talud y pendiente máxima.

### Selección requerida

Selecciona exactamente dos grupos antes de validar:

- El terreno debe contener caras.
- El eje debe contener aristas y no contener caras.

La selección puede validarse desde el formulario. Los parámetros se aceptan solo cuando la selección es válida y los valores numéricos están dentro de rango. Al pulsar **Generar vía**, el motor ordena el eje, rechaza desconexiones y ramificaciones, genera estaciones Catmull–Rom, proyecta cotas sobre el terreno y ajusta el perfil longitudinal. Después extruye la sección y crea cuatro grupos independientes: `Grupo de Vía`, `Grupo de Acera`, `Grupo de Bordillo` y `Grupo de Talud`. El ancho de bordillo está incluido dentro del ancho de acera. Los taludes enlazan el borde exterior de acera con cotas del terreno muestreadas en el ancho de proyección indicado.

La excepción de pendiente máxima se aplica al tramo abierto que desciende monotónicamente desde una cota alta hasta una cota baja. Las Fases 1–3 están implementadas; el recorte del terreno, la costura orgánica y la fusión de taludes cercanos quedan para la Fase 4.

### Instalación para desarrollo

Ejecuta `Instalar_o_actualizar_Vias_Topograficas.bat` para instalar o actualizar en SketchUp 2026. El script guarda una copia de seguridad de los archivos anteriores. Reinicia SketchUp después de instalar.
