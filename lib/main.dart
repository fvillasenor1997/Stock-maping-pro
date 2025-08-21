import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const MyApp());
}

// --- Modelo de Datos con capacidad de serialización ---
class InventoryItem {
  String name;
  InventoryItem({required this.name});

  // Convierte un objeto InventoryItem a un mapa para guardarlo en JSON.
  Map<String, dynamic> toJson() => {'name': name};

  // Crea un objeto InventoryItem a partir de un mapa (leído desde JSON).
  factory InventoryItem.fromJson(Map<String, dynamic> json) {
    return InventoryItem(name: json['name']);
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gestor de Inventario Interactivo',
      theme: ThemeData(
        primarySwatch: Colors.deepOrange,
        scaffoldBackgroundColor: Colors.grey[100],
        useMaterial3: true,
        fontFamily: 'Inter',
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 1,
          titleTextStyle: TextStyle(color: Colors.black87, fontSize: 20, fontWeight: FontWeight.bold),
          iconTheme: IconThemeData(color: Colors.black87),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          filled: true,
          fillColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.deepOrange,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ),
      home: const InventoryManagerPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class InventoryManagerPage extends StatefulWidget {
  const InventoryManagerPage({super.key});

  @override
  State<InventoryManagerPage> createState() => _InventoryManagerPageState();
}

class _InventoryManagerPageState extends State<InventoryManagerPage> {
  // --- Variables de Estado ---
  Uint8List? _imageBytes;
  String? _imagePath; // Guardamos la ruta de la imagen para asociarla al archivo de datos.
  final TextEditingController _rowsController = TextEditingController(text: '3');
  final TextEditingController _colsController = TextEditingController(text: '4');

  Map<int, List<InventoryItem>> _inventory = {};
  final GlobalKey _imageKey = GlobalKey();

  // --- Lógica de Persistencia de Datos ---

  /// Obtiene la ruta del archivo JSON asociado a la imagen actual.
  String? _getDatabasePath() {
    if (_imagePath == null) return null;
    // El archivo .json se guardará en el mismo directorio que la imagen.
    return '$_imagePath.json';
  }

  /// Guarda el estado actual del inventario en el archivo JSON.
  Future<void> _saveInventory() async {
    final path = _getDatabasePath();
    if (path == null) return;

    try {
      // Convertimos el mapa de inventario a un formato compatible con JSON.
      final Map<String, dynamic> jsonMap = _inventory.map(
        (key, value) => MapEntry(
          key.toString(),
          value.map((item) => item.toJson()).toList(),
        ),
      );
      final jsonString = jsonEncode(jsonMap);
      final file = File(path);
      await file.writeAsString(jsonString);
      debugPrint('Inventario guardado en: $path');
    } catch (e) {
      debugPrint('Error al guardar el inventario: $e');
      // Opcional: Mostrar un error al usuario.
    }
  }

  /// Carga el inventario desde el archivo JSON si existe.
  Future<void> _loadInventory() async {
    final path = _getDatabasePath();
    if (path == null) return;

    try {
      final file = File(path);
      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final Map<String, dynamic> jsonMap = jsonDecode(jsonString);

        // Convertimos el mapa leído de JSON de vuelta al formato de nuestro inventario.
        final loadedInventory = jsonMap.map(
          (key, value) => MapEntry(
            int.parse(key),
            (value as List).map((itemJson) => InventoryItem.fromJson(itemJson)).toList(),
          ),
        );
        setState(() {
          _inventory = loadedInventory;
        });
        debugPrint('Inventario cargado desde: $path');
      } else {
        // Si no hay archivo, empezamos con un inventario vacío.
        setState(() {
          _inventory = {};
        });
      }
    } catch (e) {
      debugPrint('Error al cargar el inventario: $e');
      // Si el archivo está corrupto, empezamos de cero.
      setState(() {
        _inventory = {};
      });
    }
  }

  // --- Lógica Principal de la UI ---

  Future<void> _pickImage() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );

    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      setState(() {
        _imageBytes = file.readAsBytesSync();
        _imagePath = file.path;
      });
      // Después de cargar la imagen, intentamos cargar su inventario asociado.
      await _loadInventory();
    }
  }

  Future<void> _manageCellInventory(int cellIndex) async {
    List<InventoryItem> currentItems = List.from(_inventory[cellIndex] ?? []);

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return CellInventoryDialog(
          items: currentItems,
          cellIndex: cellIndex,
          onSave: (updatedItems) {
            setState(() {
              _inventory[cellIndex] = updatedItems;
            });
            // Guardamos los cambios en el archivo cada vez que se modifica una celda.
            _saveInventory();
          },
        );
      },
    );
  }

  void _reset() {
    setState(() {
      _imageBytes = null;
      _imagePath = null;
      _inventory = {};
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestor de Inventario de Racks'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          bool isWideScreen = constraints.maxWidth > 800;
          if (isWideScreen) {
            return Row(
              children: [
                SizedBox(width: 350, child: _buildControlPanel()),
                const VerticalDivider(width: 1),
                Expanded(child: _buildDisplayArea()),
              ],
            );
          } else {
            return SingleChildScrollView(
              child: Column(
                children: [_buildControlPanel(), const Divider(height: 1), _buildDisplayArea()],
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text("Configuración del Rack", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            controller: _rowsController,
            decoration: const InputDecoration(labelText: 'Número de Filas'),
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _colsController,
            decoration: const InputDecoration(labelText: 'Número de Columnas'),
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.upload_file),
            label: const Text('Cargar Imagen del Rack'),
          ),
          const SizedBox(height: 16),
          if (_imageBytes != null)
            TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.refresh),
              label: const Text("Empezar de Nuevo"),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
        ],
      ),
    );
  }

  Widget _buildDisplayArea() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: _imageBytes == null
            ? const Text('Sube una imagen para comenzar', style: TextStyle(fontSize: 18, color: Colors.grey))
            : InteractiveViewer(
                panEnabled: true,
                minScale: 0.5,
                maxScale: 4.0,
                child: Stack(
                  key: _imageKey,
                  children: [
                    Image.memory(_imageBytes!),
                    Positioned.fill(
                      child: _buildInteractiveGrid(),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildInteractiveGrid() {
    final int rows = int.tryParse(_rowsController.text) ?? 1;
    final int cols = int.tryParse(_colsController.text) ?? 1;

    return LayoutBuilder(builder: (context, constraints) {
      return GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          childAspectRatio: constraints.maxWidth / constraints.maxHeight,
        ),
        itemCount: rows * cols,
        itemBuilder: (context, index) {
          final itemsInCell = _inventory[index] ?? [];
          return InkWell(
            onTap: () => _manageCellInventory(index),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.yellow, width: 2),
                color: itemsInCell.isEmpty
                    ? Colors.black.withOpacity(0.15)
                    : Colors.blue.withOpacity(0.35),
              ),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${itemsInCell.length} Artículos',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          );
        },
      );
    });
  }
}


class CellInventoryDialog extends StatefulWidget {
  final List<InventoryItem> items;
  final int cellIndex;
  final Function(List<InventoryItem>) onSave;

  const CellInventoryDialog({
    super.key,
    required this.items,
    required this.cellIndex,
    required this.onSave,
  });

  @override
  State<CellInventoryDialog> createState() => _CellInventoryDialogState();
}

class _CellInventoryDialogState extends State<CellInventoryDialog> {
  late List<InventoryItem> _currentItems;
  final TextEditingController _addItemController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _currentItems = List.from(widget.items.map((item) => InventoryItem(name: item.name)));
  }

  void _addItem() {
    if (_addItemController.text.isNotEmpty) {
      setState(() {
        _currentItems.add(InventoryItem(name: _addItemController.text));
        _addItemController.clear();
      });
    }
  }

  void _removeItem(int index) {
    // Muestra un diálogo de confirmación antes de eliminar.
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirmar Eliminación'),
          content: Text('¿Estás seguro de que quieres eliminar "${_currentItems[index].name}"?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancelar'),
              onPressed: () {
                Navigator.of(context).pop(); // Cierra el diálogo de confirmación
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Eliminar'),
              onPressed: () {
                setState(() {
                  _currentItems.removeAt(index);
                });
                Navigator.of(context).pop(); // Cierra el diálogo de confirmación
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Gestionar Espacio #${widget.cellIndex + 1}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addItemController,
                    decoration: const InputDecoration(labelText: 'Nombre del Artículo'),
                    onSubmitted: (_) => _addItem(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Colors.green, size: 30),
                  onPressed: _addItem,
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _currentItems.isEmpty
                  ? const Center(child: Text('Este espacio está vacío.'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _currentItems.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          title: Text(_currentItems[index].name),
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                            onPressed: () => _removeItem(index),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onSave(_currentItems);
            Navigator.of(context).pop();
          },
          child: const Text('Guardar Cambios'),
        ),
      ],
    );
  }
}
