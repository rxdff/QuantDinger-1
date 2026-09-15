"""
Alpaca Markets API Routes

Standalone API endpoints for US stocks, ETFs, and crypto trading via Alpaca.
Mirrors the structure of routes/ibkr.py for consistency.

Multi-tenancy: connections are isolated per authenticated user via
:class:`BrokerSessionRegistry` instead of a process-wide global, so users
cannot accidentally place orders through someone else's Alpaca account.
"""

import os

from flask import Blueprint, request, jsonify
from app.utils.auth import login_required
from app.utils.logger import get_logger
from app.utils.broker_session import BrokerSessionRegistry
from app.services.alpaca_trading import AlpacaClient, AlpacaConfig

logger = get_logger(__name__)

alpaca_bp = Blueprint('alpaca', __name__)

# Per-user client cache keyed by (user_id, 'alpaca')
_sessions = BrokerSessionRegistry('alpaca')


def _placeholder_status():
    """Return a stable 'not connected' status when no client exists yet."""
    return {
        "connected": False,
        "paper": True,
        "base_url": "https://paper-api.alpaca.markets",
        "account_id": None,
    }


def _autoconnect_from_env():
    """单机部署便利：当用户没显式调 /connect 时，若 .env 配了 ALPACA key 就自动连。"""
    api_key = os.getenv('ALPACA_API_KEY', '').strip()
    secret_key = os.getenv('ALPACA_SECRET_KEY', '').strip()
    if not api_key or not secret_key:
        return None
    try:
        client = AlpacaClient(AlpacaConfig(
            api_key=api_key,
            secret_key=secret_key,
            paper=os.getenv('ALPACA_PAPER', 'true').strip().lower() != 'false',
        ))
        if client.connect():
            _sessions.set(client)
            logger.info("Alpaca auto-connected from env (paper=%s)", client.config.paper)
            return client
    except Exception as exc:
        logger.warning("Alpaca auto-connect failed: %s", exc)
    return None


# ==================== Connection Management ====================

@alpaca_bp.route('/status', methods=['GET'])
@login_required
def get_status():
    """Get connection status. GET /api/alpaca/status"""
    try:
        client = _sessions.get()
        if client is None or not client.connected:
            client = _autoconnect_from_env() or client
        if client is None:
            return jsonify({"success": True, "data": _placeholder_status()})
        return jsonify({"success": True, "data": client.get_connection_status()})
    except Exception as e:
        logger.error(f"Get status failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@alpaca_bp.route('/connect', methods=['POST'])
@login_required
def connect():
    """
    Connect to Alpaca. POST /api/alpaca/connect
    Body: {
        "apiKey": "PK...",        // Required (PK prefix = paper, AK = live)
        "secretKey": "...",       // Required
        "paper": true,            // Optional, default true
        "baseUrl": ""             // Optional, override
    }
    """
    try:
        data = request.get_json() or {}
        api_key = data.get('apiKey', '')
        secret_key = data.get('secretKey', '')
        if not api_key or not secret_key:
            return jsonify({"success": False, "error": "apiKey and secretKey required"}), 400

        config = AlpacaConfig(
            api_key=api_key,
            secret_key=secret_key,
            paper=bool(data.get('paper', True)),
            base_url=data.get('baseUrl') or None,
        )

        client = AlpacaClient(config)
        success = client.connect()
        if success:
            _sessions.set(client)
            return jsonify({
                "success": True,
                "message": "Connected successfully",
                "data": client.get_connection_status(),
            })
        return jsonify({
            "success": False,
            "error": "Connection failed. Verify API keys and network access to api.alpaca.markets.",
        }), 400
    except ImportError:
        return jsonify({
            "success": False,
            "error": "alpaca-py not installed. Run: pip install alpaca-py",
        }), 500
    except Exception as e:
        logger.error(f"Alpaca connection failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@alpaca_bp.route('/disconnect', methods=['POST'])
@login_required
def disconnect():
    """Disconnect from Alpaca. POST /api/alpaca/disconnect"""
    try:
        _sessions.disconnect_current()
        return jsonify({"success": True, "message": "Disconnected"})
    except Exception as e:
        logger.error(f"Disconnect failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


# ==================== Account Queries ====================

def _require_connected_client():
    client = _sessions.get()
    if client is None or not client.connected:
        client = _autoconnect_from_env()
    if client is None or not client.connected:
        return None, (jsonify({"success": False, "error": "Not connected to Alpaca"}), 400)
    return client, None


@alpaca_bp.route('/account', methods=['GET'])
@login_required
def get_account():
    """Get account information. GET /api/alpaca/account"""
    try:
        client, err = _require_connected_client()
        if err is not None:
            return err
        return jsonify({"success": True, "data": client.get_account_summary()})
    except Exception as e:
        logger.error(f"Get account info failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@alpaca_bp.route('/positions', methods=['GET'])
@login_required
def get_positions():
    """Get positions. GET /api/alpaca/positions"""
    try:
        client, err = _require_connected_client()
        if err is not None:
            return err
        return jsonify({"success": True, "data": client.get_positions()})
    except Exception as e:
        logger.error(f"Get positions failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@alpaca_bp.route('/orders', methods=['GET'])
@login_required
def get_orders():
    """Get orders. GET /api/alpaca/orders?status=open|closed|all&limit=500"""
    try:
        client, err = _require_connected_client()
        if err is not None:
            return err
        status = request.args.get('status', 'open')
        try:
            limit = int(request.args.get('limit', 500))
        except ValueError:
            limit = 500
        return jsonify({"success": True, "data": client.get_open_orders(status=status, limit=limit)})
    except Exception as e:
        logger.error(f"Get orders failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


# ==================== Trading ====================

@alpaca_bp.route('/order', methods=['POST'])
@login_required
def place_order():
    """
    Place an order. POST /api/alpaca/order
    Body: {
        "symbol": "AAPL",           // Required
        "side": "buy",              // Required, buy or sell
        "quantity": 10,             // Required, number of shares
        "marketType": "USStock",    // Optional, USStock or crypto
        "orderType": "market",      // Optional, market or limit
        "price": 150.00,            // Required for limit
        "extendedHours": false      // Optional, for limit orders pre/post-market
    }
    """
    try:
        client, err = _require_connected_client()
        if err is not None:
            return err

        data = request.get_json() or {}
        symbol = data.get('symbol')
        side = data.get('side')
        quantity = data.get('quantity')
        if not symbol:
            return jsonify({"success": False, "error": "Missing symbol"}), 400
        if not side or side.lower() not in ('buy', 'sell'):
            return jsonify({"success": False, "error": "side must be buy or sell"}), 400
        if not quantity or float(quantity) <= 0:
            return jsonify({"success": False, "error": "quantity must be > 0"}), 400

        market_type = data.get('marketType', 'USStock')
        order_type = (data.get('orderType') or 'market').lower()

        if order_type == 'limit':
            price = data.get('price')
            if not price or float(price) <= 0:
                return jsonify({"success": False, "error": "Limit order requires price"}), 400
            result = client.place_limit_order(
                symbol=symbol, side=side, quantity=float(quantity), price=float(price),
                market_type=market_type, extended_hours=bool(data.get('extendedHours', False)),
                time_in_force=str(data.get('timeInForce') or 'GTC'),
            )
        else:
            result = client.place_market_order(
                symbol=symbol, side=side, quantity=float(quantity), market_type=market_type,
            )

        if result.success:
            return jsonify({
                "success": True,
                "message": result.message,
                "data": {
                    "orderId": result.order_id, "filled": result.filled,
                    "avgPrice": result.avg_price, "status": result.status, "raw": result.raw,
                },
            })
        return jsonify({"success": False, "error": result.message, "data": result.raw}), 400
    except Exception as e:
        logger.error(f"Place order failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@alpaca_bp.route('/order/<order_id>', methods=['DELETE'])
@login_required
def cancel_order(order_id):
    """Cancel order. DELETE /api/alpaca/order/<order_id>"""
    try:
        client, err = _require_connected_client()
        if err is not None:
            return err
        ok = client.cancel_order(order_id)
        return jsonify({"success": ok, "message": "Cancelled" if ok else "Cancel failed"})
    except Exception as e:
        logger.error(f"Cancel order failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


# ==================== Market Data ====================

@alpaca_bp.route('/quote/<symbol>', methods=['GET'])
@login_required
def get_quote(symbol):
    """Get real-time quote. GET /api/alpaca/quote/<symbol>?marketType=USStock"""
    try:
        client, err = _require_connected_client()
        if err is not None:
            return err
        market_type = request.args.get('marketType', 'USStock')
        result = client.get_quote(symbol, market_type=market_type)
        if result.get('success'):
            return jsonify({"success": True, "data": result})
        return jsonify({"success": False, "error": result.get('error', 'Quote failed')}), 400
    except Exception as e:
        logger.error(f"Get quote failed: {e}")
        return jsonify({"success": False, "error": str(e)}), 500
