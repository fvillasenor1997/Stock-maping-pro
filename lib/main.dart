import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; // <-- CORRECCIÓN AQUÍ
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:csv/csv.dart';

// --- MODELOS DE DATOS ---
class InventoryItem {
  int? id;
  final String rackId;
  final int cellIndex;
  String partNumber;
  int quantity;
  String? description; // Se poblará desde la tabla maestra

  InventoryItem({
    this.id,
    required this.rackId,
    required this.cellIndex,
    required this.partNumber,
    this.quantity = 1,
    this.description,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'rackId': rackId,
      'cellIndex': cellIndex,
      'partNumber': partNumber,
      'quantity': quantity,
    };
  }

  factory InventoryItem.fromMap(Map<String, dynamic> map) {
    return InventoryItem(
      id: map['id'],
      rackId: map['rackId'],
      cellIndex: map['cellIndex'],
      partNumber: map['partNumber'],
      quantity: map['quantity'],
    );
  }
}

class MasterPart {
  final String partNumber;
  final String description;

  MasterPart({required this.partNumber, required this.description});

  Map<String, dynamic> toMap() {
    return {'partNumber': partNumber, 'description': description};
  }
}


// --- GESTOR DE LA BASE DE DATOS ---
class DatabaseHelper {
  static Database? _database;
  static final DatabaseHelper instance = DatabaseHelper._init();
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('corporate_inventory_v2.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      rackId TEXT NOT NULL,
      cellIndex INTEGER NOT NULL,
      partNumber TEXT NOT NULL,
      quantity INTEGER NOT NULL
    )
    ''');
    await db.execute('''
    CREATE TABLE master_parts (
      partNumber TEXT PRIMARY KEY,
      description TEXT NOT NULL
    )
    ''');
  }

  // --- Operaciones con Items ---
  Future<InventoryItem> createItem(InventoryItem item) async {
    final db = await instance.database;
    final id = await db.insert('items', item.toMap());
    item.id = id;
    return item;
  }

  Future<Map<int, List<InventoryItem>>> getItemsForRack(String rackId) async {
    final db = await instance.database;
    final result = await db.query('items', where: 'rackId = ?', whereArgs: [rackId]);
    Map<int, List<InventoryItem>> inventoryMap = {};
    for (var map in result) {
      final item = InventoryItem.fromMap(map);
      item.description = await getPartDescription(item.partNumber);
      if (!inventoryMap.containsKey(item.cellIndex)) {
        inventoryMap[item.cellIndex] = [];
      }
      inventoryMap[item.cellIndex]!.add(item);
    }
    return inventoryMap;
  }

  Future<int> deleteItem(int id) async {
    final db = await instance.database;
    return await db.delete('items', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<String>> getDistinctRackIds() async {
    final db = await instance.database;
    final result = await db.rawQuery('SELECT DISTINCT rackId FROM items ORDER BY rackId');
    return result.map((map) => map['rackId'] as String).toList();
  }

  // --- Operaciones con Maestro de Partes ---
  Future<String?> getPartDescription(String partNumber) async {
    final db = await instance.database;
    final result = await db.query('master_parts',
        columns: ['description'], where: 'partNumber = ?', whereArgs: [partNumber]);
    if (result.isNotEmpty) {
      return result.first['description'] as String?;
    }
    return null;
  }

  Future<int> loadMasterPartsFromCsv(String filePath) async {
    final file = File(filePath);
    final content = await file.readAsString(encoding: utf8);
    final List<List<dynamic>> rows = const CsvToListConverter().convert(content);
    
    final db = await instance.database;
    final batch = db.batch();
    int count = 0;
    
    // Asume que la primera fila es el encabezado y la ignora
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.length >= 2) {
        final part = MasterPart(partNumber: row[0].toString(), description: row[1].toString());
        batch.insert('master_parts', part.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
        count++;
      }
    }
    await batch.commit(noResult: true);
    return count;
  }
}


// --- PUNTO DE ENTRADA DE LA APP ---
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gestor de Inventario Corporativo',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        useMaterial3: true,
        fontFamily: 'Inter',
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 1,
          titleTextStyle: TextStyle(color: Color(0xFF1A2533), fontSize: 20, fontWeight: FontWeight.bold),
          iconTheme: IconThemeData(color: Color(0xFF1A2533)),
        ),
        cardTheme: CardTheme(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFE0E0E0)),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.indigo[700],
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}


// --- PANTALLA DE INICIO ---
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<String>> _racksFuture;

  @override
  void initState() {
    super.initState();
    _racksFuture = DatabaseHelper.instance.getDistinctRackIds();
  }

  void _refreshRacks() {
    setState(() {
      _racksFuture = DatabaseHelper.instance.getDistinctRackIds();
    });
  }

  Future<void> _loadNewRack() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final rackId = p.basename(file.path);
      final imageBytes = await file.readAsBytes();
      
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => InventoryManagerPage(
            rackId: rackId,
            imageBytes: imageBytes,
          ),
        ),
      );
      _refreshRacks();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel Principal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Bienvenido al Sistema de Gestión de Inventario',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadNewRack,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Cargar Nuevo Rack'),
            ),
            const Divider(height: 48),
            const Text('Racks Disponibles en el Sistema',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Expanded(
              child: FutureBuilder<List<String>>(
                future: _racksFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (!snapshot.hasData || snapshot.data!.isEmpty) {
                    return const Center(child: Text('No hay racks guardados en el sistema.'));
                  }
                  final racks = snapshot.data!;
                  return ListView.builder(
                    itemCount: racks.length,
                    itemBuilder: (context, index) {
                      final rackId = racks[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ListTile(
                          leading: const Icon(Icons.grid_on, color: Colors.indigo),
                          title: Text(rackId, style: const TextStyle(fontWeight: FontWeight.bold)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            // Nota: Para abrir un rack existente, necesitaríamos guardar
                            // la ruta de la imagen o mostrar un placeholder.
                            // Por simplicidad, esta acción está pendiente.
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Funcionalidad para abrir "${rackId}" pendiente.')),
                            );
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// --- PANTALLA DE GESTIÓN DE INVENTARIO ---
class InventoryManagerPage extends StatefulWidget {
  final String rackId;
  final Uint8List imageBytes;

  const InventoryManagerPage({super.key, required this.rackId, required this.imageBytes});

  @override
  State<InventoryManagerPage> createState() => _InventoryManagerPageState();
}

class _InventoryManagerPageState extends State<InventoryManagerPage> {
  final TextEditingController _rowsController = TextEditingController(text: '3');
  final TextEditingController _colsController = TextEditingController(text: '4');
  Map<int, List<InventoryItem>> _inventory = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadInventory();
  }

  Future<void> _loadInventory() async {
    setState(() { _isLoading = true; });
    final allItems = await DatabaseHelper.instance.getItemsForRack(widget.rackId);
    setState(() {
      _inventory = allItems;
      _isLoading = false;
    });
  }

  Future<void> _manageCellInventory(int cellIndex) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => CellInventoryDialog(
        cellIndex: cellIndex,
        rackId: widget.rackId,
      ),
    );
    if (result == true) {
      _loadInventory();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Gestionando: ${widget.rackId}')),
      body: Row(
        children: [
          SizedBox(width: 350, child: _buildControlPanel()),
          const VerticalDivider(width: 1, color: Color(0xFFE0E0E0)),
          Expanded(child: _buildDisplayArea()),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Configuración de la Cuadrícula", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const Divider(height: 24),
          TextField(
            controller: _rowsController,
            decoration: const InputDecoration(labelText: 'Número de Filas', border: OutlineInputBorder()),
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _colsController,
            decoration: const InputDecoration(labelText: 'Número de Columnas', border: OutlineInputBorder()),
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }

  Widget _buildDisplayArea() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Card(
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(widget.imageBytes, fit: BoxFit.cover),
                  _buildInteractiveGrid(),
                ],
              ),
            ),
    );
  }

  Widget _buildInteractiveGrid() {
    final int rows = int.tryParse(_rowsController.text) ?? 1;
    final int cols = int.tryParse(_colsController.text) ?? 1;

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols),
      itemCount: rows * cols,
      itemBuilder: (context, index) {
        final itemsInCell = _inventory[index] ?? [];
        final totalQuantity = itemsInCell.fold<int>(0, (sum, item) => sum + item.quantity);
        final bool isEmpty = itemsInCell.isEmpty;

        return InkWell(
          onTap: () => _manageCellInventory(index),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: isEmpty ? Colors.grey.withOpacity(0.5) : Colors.indigo, width: isEmpty ? 1 : 2),
              color: isEmpty ? Colors.black.withOpacity(0.05) : Colors.indigo.withOpacity(0.2),
            ),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isEmpty ? Colors.black.withOpacity(0.4) : Colors.indigo[700],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isEmpty ? 'Vacío' : '$totalQuantity Unidades',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}


// --- PANTALLA DE AJUSTES ---
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isLoading = false;

  Future<void> _importMasterParts() async {
    setState(() { _isLoading = true; });
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (result != null && result.files.single.path != null) {
        final count = await DatabaseHelper.instance.loadMasterPartsFromCsv(result.files.single.path!);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$count registros importados/actualizados en el maestro de partes.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al importar el archivo: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Gestión de Datos Maestros', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.upload_file, color: Colors.indigo),
                title: const Text('Importar Maestro de Partes'),
                subtitle: const Text('Carga un archivo CSV (partNumber, description)'),
                trailing: _isLoading ? const CircularProgressIndicator() : const Icon(Icons.chevron_right),
                onTap: _isLoading ? null : _importMasterParts,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// --- DIÁLOGO DE GESTIÓN DE CELDA ---
class CellInventoryDialog extends StatefulWidget {
  final int cellIndex;
  final String rackId;

  const CellInventoryDialog({super.key, required this.cellIndex, required this.rackId});

  @override
  State<CellInventoryDialog> createState() => _CellInventoryDialogState();
}

class _CellInventoryDialogState extends State<CellInventoryDialog> {
  List<InventoryItem> _items = [];
  final TextEditingController _partNumberController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController(text: '1');
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _refreshItems();
  }

  Future<void> _refreshItems() async {
    setState(() { _isLoading = true; });
    final data = await DatabaseHelper.instance.getItemsForRack(widget.rackId);
    setState(() {
      _items = data[widget.cellIndex] ?? [];
      _isLoading = false;
    });
  }

  Future<void> _addItem() async {
    if (_partNumberController.text.isNotEmpty) {
      final newItem = InventoryItem(
        rackId: widget.rackId,
        cellIndex: widget.cellIndex,
        partNumber: _partNumberController.text,
        quantity: int.tryParse(_quantityController.text) ?? 1,
      );
      await DatabaseHelper.instance.createItem(newItem);
      _partNumberController.clear();
      _quantityController.text = '1';
      _refreshItems();
    }
  }

  Future<void> _deleteItem(int id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar Eliminación'),
        content: const Text('¿Está seguro de que desea eliminar este artículo?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Eliminar'), style: TextButton.styleFrom(foregroundColor: Colors.red)),
        ],
      ),
    );
    if (confirm == true) {
      await DatabaseHelper.instance.deleteItem(id);
      _refreshItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Gestionar Espacio #${widget.cellIndex + 1}'),
      content: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: TextField(controller: _partNumberController, decoration: const InputDecoration(labelText: 'Número de Parte', border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                SizedBox(width: 80, child: TextField(controller: _quantityController, decoration: const InputDecoration(labelText: 'Cant.', border: OutlineInputBorder()), keyboardType: TextInputType.number)),
                IconButton(icon: const Icon(Icons.add_circle, color: Colors.green, size: 32), onPressed: _addItem),
              ],
            ),
            const Divider(height: 24),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? const Center(child: Text('Este espacio está vacío.'))
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: ListTile(
                                title: Text(item.partNumber, style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text(item.description ?? 'Sin descripción'),
                                leading: CircleAvatar(child: Text(item.quantity.toString())),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                                  onPressed: () => _deleteItem(item.id!),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}
