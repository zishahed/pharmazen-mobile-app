import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_providers.dart';
import 'api_client.dart';

class AdminStats {
  const AdminStats({
    required this.totalUsers,
    required this.totalCustomers,
    required this.totalPharmacists,
    required this.totalMedicines,
    required this.totalOrders,
    required this.pendingPrescriptions,
    required this.lowStockCount,
    required this.totalRevenue,
  });

  final int totalUsers;
  final int totalCustomers;
  final int totalPharmacists;
  final int totalMedicines;
  final int totalOrders;
  final int pendingPrescriptions;
  final int lowStockCount;
  final num totalRevenue;

  factory AdminStats.fromJson(Map<String, dynamic> json) => AdminStats(
    totalUsers: _int(json['totalUsers']),
    totalCustomers: _int(json['totalCustomers']),
    totalPharmacists: _int(json['totalPharmacists']),
    totalMedicines: _int(json['totalMedicines']),
    totalOrders: _int(json['totalOrders']),
    pendingPrescriptions: _int(json['pendingPrescriptions']),
    lowStockCount: _int(json['lowStockCount']),
    totalRevenue: json['totalRevenue'] is num
        ? json['totalRevenue'] as num
        : num.tryParse('${json['totalRevenue']}') ?? 0,
  );
}

class AdminUser {
  const AdminUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
    required this.createdAt,
    required this.orderCount,
  });

  final String id;
  final String name;
  final String email;
  final String role;
  final bool isActive;
  final DateTime createdAt;
  final int orderCount;

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    email: (json['email'] as String?) ?? '',
    role: (json['role'] as String?) ?? 'customer',
    isActive: json['isActive'] as bool? ?? true,
    createdAt: DateTime.parse(json['createdAt'] as String),
    orderCount: _int(json['orderCount']),
  );
}

class AdminMedicine {
  const AdminMedicine({
    required this.id,
    required this.name,
    required this.description,
    required this.categoryId,
    required this.price,
    required this.stockQuantity,
    required this.expiryDate,
    required this.requiresPrescription,
  });

  final String id;
  final String name;
  final String? description;
  final String categoryId;
  final num price;
  final int stockQuantity;
  final DateTime? expiryDate;
  final bool requiresPrescription;

  factory AdminMedicine.fromJson(Map<String, dynamic> json) => AdminMedicine(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    description: json['description'] as String?,
    categoryId: (json['categoryId'] as String?) ?? '',
    price: json['price'] is num
        ? json['price'] as num
        : num.tryParse('${json['price']}') ?? 0,
    stockQuantity: _int(json['stockQuantity']),
    expiryDate: json['expiryDate'] == null
        ? null
        : DateTime.tryParse(json['expiryDate'] as String),
    requiresPrescription:
        json['isSensitive'] as bool? ??
        json['requiresPrescription'] as bool? ??
        false,
  );
}

class AdminOrder {
  const AdminOrder({
    required this.id,
    required this.customerName,
    required this.customerEmail,
    required this.totalAmount,
    required this.status,
    required this.paymentStatus,
    required this.createdAt,
  });

  final String id;
  final String customerName;
  final String customerEmail;
  final num totalAmount;
  final String status;
  final String paymentStatus;
  final DateTime createdAt;

  factory AdminOrder.fromJson(Map<String, dynamic> json) => AdminOrder(
    id: json['id'] as String,
    customerName: (json['customerName'] as String?) ?? 'Unknown customer',
    customerEmail: (json['customerEmail'] as String?) ?? '',
    totalAmount: json['totalAmount'] is num
        ? json['totalAmount'] as num
        : num.tryParse('${json['totalAmount']}') ?? 0,
    status: (json['status'] as String?) ?? '',
    paymentStatus: (json['paymentStatus'] as String?) ?? '',
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

int _int(Object? value) => value is num ? value.toInt() : 0;

class AdminApiException implements Exception {
  const AdminApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

final adminApiClientProvider = Provider<AdminApiClient>(
  (ref) => AdminApiClient(ref.watch(apiClientProvider)),
);

class AdminApiClient {
  AdminApiClient(this._api);

  final ApiClient _api;

  Future<AdminStats> getStats() async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>('/admin/stats');
      final data = response.data?['data'];
      if (data is! Map<String, dynamic>) {
        throw const AdminApiException(
          'The server sent invalid dashboard data.',
        );
      }
      return AdminStats.fromJson(data);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ??
            'Could not load the admin dashboard.',
      );
    }
  }

  Future<List<AdminUser>> listUsers({String? role}) async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>(
        '/admin/users',
        queryParameters: {'role': ?role},
      );
      final data = response.data?['data'];
      final users = data is Map<String, dynamic> ? data['users'] : data;
      if (users is! List) {
        throw const AdminApiException('The server sent invalid user data.');
      }
      return users
          .whereType<Map<String, dynamic>>()
          .map(AdminUser.fromJson)
          .toList(growable: false);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not load users.',
      );
    }
  }

  Future<AdminUser> setUserActive({
    required String id,
    required bool isActive,
  }) async {
    try {
      final response = await _api.dio.patch<Map<String, dynamic>>(
        '/admin/users/$id/status',
        data: {'isActive': isActive},
      );
      final data = response.data?['data'];
      if (data is! Map<String, dynamic>) {
        throw const AdminApiException('The server sent invalid user data.');
      }
      return AdminUser.fromJson(data);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not update user status.',
      );
    }
  }

  Future<List<AdminMedicine>> listMedicines({String? search}) async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>(
        '/medicines',
        queryParameters: {'limit': 100, 'search': ?search},
      );
      final data = response.data?['data'];
      final medicines = data is Map<String, dynamic> ? data['medicines'] : data;
      if (medicines is! List) {
        throw const AdminApiException('The server sent invalid medicine data.');
      }
      return medicines
          .whereType<Map<String, dynamic>>()
          .map(AdminMedicine.fromJson)
          .toList(growable: false);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not load medicines.',
      );
    }
  }

  Future<AdminMedicine> saveMedicine(
    Map<String, dynamic> data, {
    String? id,
  }) async {
    try {
      final response = id == null
          ? await _api.dio.post<Map<String, dynamic>>('/medicines', data: data)
          : await _api.dio.put<Map<String, dynamic>>(
              '/medicines/$id',
              data: data,
            );
      final result = response.data?['data'];
      if (result is! Map<String, dynamic>) {
        throw const AdminApiException('The server sent invalid medicine data.');
      }
      return AdminMedicine.fromJson(result);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not save medicine.',
      );
    }
  }

  Future<void> deleteMedicine(String id) async {
    try {
      await _api.dio.delete<Map<String, dynamic>>('/medicines/$id');
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not delete medicine.',
      );
    }
  }

  Future<List<AdminOrder>> listOrders({String? customer}) async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>(
        '/admin/orders',
        queryParameters: {'search': ?customer},
      );
      final data = response.data?['data'];
      final orders = data is Map<String, dynamic> ? data['orders'] : data;
      if (orders is! List) {
        throw const AdminApiException('The server sent invalid order data.');
      }
      return orders
          .whereType<Map<String, dynamic>>()
          .map(AdminOrder.fromJson)
          .toList(growable: false);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not load orders.',
      );
    }
  }
}
